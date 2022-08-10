defmodule Membrane.VideoMixer do
  @moduledoc """
  This element performs video mixing.
  """

  use Membrane.Filter
  use Bunch

  require Membrane.Logger

  alias Membrane.{Buffer, RawVideo, Time}
  alias Membrane.VideoMixer.{Mixer, FrameQueue}

  def_options(
    output_caps: [
      type: :struct,
      spec: RawVideo.t(),
      description: """
      Defines the caps of the output video.
      """,
      default: nil
    ],
    filters: [
      type: :struct,
      spec: (width :: integer, height :: integer, inputs :: integer -> String.t()),
      description: """
      Defines the filter building function.
      """,
      default: nil
    ]
  )

  def_input_pad :input,
    mode: :pull,
    availability: :on_request,
    demand_unit: :buffers,
    caps: RawVideo

  def_output_pad :output,
    mode: :pull,
    availability: :always,
    demand_unit: :buffers,
    caps: RawVideo

  @impl true
  def handle_init(%__MODULE__{} = options) do
    state =
      options
      |> Map.from_struct()
      |> Map.put(:pads, %{})
      |> Map.put(:mixer_state, nil)
      |> put_time_information()
      |> Map.update!(:filters, fn
        nil ->
          # default filters
          fn
            width, height, 1 ->
              "[0:v]scale=#{width}:#{height}:force_original_aspect_ratio=decrease,setsar=1/1,pad=#{width}:#{height}:(ow-iw)/2:(oh-ih)/2"

            width, height, 2 ->
              "[0:v]scale=#{width}/3*2:#{height}:force_original_aspect_ratio=decrease,pad=#{width}/3*2+1:#{height}:-1:-1,setsar=1[l];[1:v]scale=-1:#{height}/3*2,crop=#{width}/3:ih:iw/3:0,pad=#{width}/3:#{height}:-1:-1,setsar=1[r];[l][r]hstack"

            _, _, n ->
              raise("No matching filter found for #{n} input(s)")
          end

        other ->
          other
      end)

    {:ok, state}
  end

  @impl true
  def handle_pad_added(pad, _context, state) do
    state =
      Bunch.Access.put_in(state, [:pads, pad], %{
        queue: FrameQueue.new(),
        stream_ended: false,
        idx: length(Map.keys(state.pads))
      })

    {:ok, state}
  end

  @impl true
  def handle_pad_removed(pad, _context, state) do
    {:ok, remove_pad(state, pad)}
  end

  @impl true
  def handle_prepared_to_playing(_context, %{output_caps: %RawVideo{} = caps} = state) do
    {{:ok, caps: {:output, caps}}, state}
  end

  @impl true
  def handle_prepared_to_stopped(_context, state) do
    {:ok, %{state | mixer_state: nil}}
  end

  @impl true
  def handle_demand(:output, buffer_count, :buffers, _context, state = %{pads: pads}) do
    pads
    |> Enum.map(fn {pad, %{queue: queue}} ->
      queue
      |> FrameQueue.frames_length()
      |> then(&{:demand, {pad, max(0, buffer_count - &1)}})
    end)
    |> then(fn demands -> {{:ok, demands}, state} end)
  end

  @impl true
  def handle_start_of_stream(_pad, _context, state) do
    mix_and_get_actions(state)
  end

  @impl true
  def handle_end_of_stream(pad, _context, state) do
    index = Bunch.Access.get_in(state, [:pads, pad, :idx])

    Membrane.Logger.debug("handle_end_of_stream: Pad nr. #{index + 1} stream ended")

    state =
      if FrameQueue.empty?(Bunch.Access.get_in(state, [:pads, pad, :queue])) do
        # no frame for ended pad is in queue: remove it
        Membrane.Logger.info("Pad nr: #{index + 1} stream ended and will be removed")

        state = remove_pad(state, pad)
        %{state | mixer_state: initialize_mixer_state(state)}
      else
        # pad will be removed as soon as its frame is empty
        Bunch.Access.update_in(state, [:pads, pad], &%{&1 | stream_ended: true})
      end

    if all_streams_ended?(state) do
      flush(state)
    else
      mix_and_get_actions(state)
    end
  end

  @impl true
  def handle_process(pad_ref, %Buffer{payload: payload}, _context, state) do
    # enqueue recieved buffer and mix if enogh buffers are in queue
    state =
      Bunch.Access.update_in(state, [:pads, pad_ref], fn pad = %{queue: queue} ->
        %{pad | queue: FrameQueue.put_frame(queue, payload)}
      end)

    mix_and_get_actions(state)
  end

  @impl true
  def handle_caps(pad_ref, caps, _context, state) do
    state =
      Bunch.Access.update_in(state, [:pads, pad_ref], fn pad = %{queue: queue} ->
        %{pad | queue: FrameQueue.put_caps(queue, caps)}
      end)

    {:ok, state}
  end

  defp initialize_mixer_state(state = %{output_caps: caps, filters: filters}) do
    inputs_caps = get_ordered_caps(state)

    case length(inputs_caps) do
      0 ->
        Membrane.Logger.info("No inputs were found and mixer was set to empty state")
        nil

      _ ->
        Mixer.init(inputs_caps, caps, filters)
    end
  end

  defp mix_and_get_actions(%{pads: pads} = state) do
    cond do
      # no pads are present
      no_streams?(state) ->
        {{:ok, [end_of_stream: :output]}, state}

      # one of the pad queues is empty, wait until we get an item
      Enum.find_value(pads, fn {_pad_ref, %{queue: queue}} ->
        FrameQueue.empty?(queue)
      end) ->
        {{:ok, [redemand: :output]}, state}

      true ->
        {payload, state} = mix(state)
        buffer = %Buffer{payload: payload, pts: state.timer}

        case remove_finished_pads(state) do
          :keep ->
            # no pad was removed
            state = increment_timer(state)

            {{:ok, [buffer: {:output, buffer}]}, state}

          {:restart, state} ->
            # pad was removed and the mixer needs to be restared
            state =
              state
              |> Map.put(:mixer_state, initialize_mixer_state(state))
              |> increment_timer()

            {{:ok, [buffer: {:output, buffer}]}, state}

          {:stop, state} ->
            # last pad was removed
            state =
              state
              |> Map.put(:mixer_state, initialize_mixer_state(state))
              |> increment_timer()

            {{:ok, [buffer: {:output, buffer}, end_of_stream: :output]}, state}
        end
    end
  end

  defp mix(state) do
    case get_ordered_payloads(state) do
      {:keep, payloads, state} ->
        mix_payloads(payloads, state)

      {:restart, payloads, state} ->
        # caps were switched so the mixer needs to be restarted
        state = %{state | mixer_state: initialize_mixer_state(state)}
        mix_payloads(payloads, state)
    end
  end

  defp get_ordered_payloads(%{pads: pads} = state) do
    # get a frame from each pad queue and sort them
    # can't be called when one of the queues is empty
    {action, {pads, payloads_with_idx}} =
      Enum.reduce(pads, {:keep, {[], []}}, fn
        {pad_ref, pad = %{queue: queue, idx: idx}}, {:restart, {pads, payloads}} ->
          {{_, payload}, queue} = FrameQueue.get_frame(queue)
          pad = %{pad | queue: queue}

          {:restart, {[{pad_ref, pad} | pads], [{idx, payload} | payloads]}}

        {pad_ref, pad = %{queue: queue, idx: idx}}, {:keep, {pads, payloads}} ->
          case FrameQueue.get_frame(queue) do
            {{:no_change, payload}, queue} ->
              pad = %{pad | queue: queue}

              {:keep, {[{pad_ref, pad} | pads], [{idx, payload} | payloads]}}

            {{:change, payload}, queue} ->
              pad = %{pad | queue: queue}

              {:restart, {[{pad_ref, pad} | pads], [{idx, payload} | payloads]}}
          end
      end)

    payloads =
      payloads_with_idx
      |> Enum.sort()
      |> Enum.map(&elem(&1, 1))

    {action, payloads, %{state | pads: Map.new(pads)}}
  end

  defp get_ordered_caps(%{pads: pads}) do
    pads
    |> Enum.filter(fn {_ref, %{queue: queue}} -> FrameQueue.initialized?(queue) end)
    |> Enum.map(fn {_pad_ref, %{queue: queue, idx: index}} ->
      {index, FrameQueue.read_caps(queue)}
    end)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  defp remove_pad(state = %{pads: pads}, pad_ref) do
    # removes a pad and rearranges the index of the remaining ones
    index = Bunch.Access.get_in(state, [:pads, pad_ref, :idx])

    pads =
      pads
      |> Enum.map(fn
        {pad_ref, pad = %{idx: idx}} when idx > index ->
          {pad_ref, %{pad | idx: idx - 1}}

        elem ->
          elem
      end)
      |> Map.new()

    state
    |> Map.put(:pads, pads)
    |> Bunch.Access.delete_in([:pads, pad_ref])
  end

  defp no_streams?(%{pads: pads}) do
    Enum.empty?(Map.keys(pads))
  end

  defp remove_finished_pads(state = %{pads: pads}) do
    # remove pads that have ended and where queue is empty
    pads
    |> Enum.reduce([], fn
      {pad_ref, %{queue: queue, stream_ended: true}}, acc ->
        if FrameQueue.empty?(queue) do
          [pad_ref | acc]
        else
          acc
        end

      _, acc ->
        acc
    end)
    |> case do
      [] ->
        :keep

      to_remove ->
        state =
          Enum.reduce(to_remove, state, fn pad_ref, state ->
            remove_pad(state, pad_ref)
          end)

        if no_streams?(state) do
          {:stop, state}
        else
          {:restart, state}
        end
    end
  end

  defp mix_payloads(payloads, %{mixer_state: mixer_state} = state) do
    payload = Mixer.mix(payloads, mixer_state)
    {payload, state}
  end

  defp all_streams_ended?(%{pads: pads}) do
    Enum.all?(pads, fn {_, %{stream_ended: stream_ended}} ->
      stream_ended
    end)
  end

  defp flush(state, result \\ []) do
    # flush all frames that are in the queue
    if no_streams?(state) do
      end_flush(state, result)
    else
      {payload, state} = mix(state)

      case remove_finished_pads(state) do
        :keep ->
          # no pad was removed
          state
          |> increment_timer()
          |> flush([%Buffer{payload: payload, pts: state.timer} | result])

        {:restart, state} ->
          # pad was removed and the mixer needs to be restared
          state
          |> Map.put(:mixer_state, initialize_mixer_state(state))
          |> increment_timer()
          |> flush([%Buffer{payload: payload, pts: state.timer} | result])

        {:stop, state} ->
          # last pad was removed
          state
          |> Map.put(:mixer_state, initialize_mixer_state(state))
          |> increment_timer()
          |> end_flush([%Buffer{payload: payload, pts: state.timer} | result])
      end
    end
  end

  defp end_flush(state, []), do: {{:ok, [end_of_stream: :output]}, state}

  defp end_flush(state, buffers) do
    {{:ok, [buffer: {:output, Enum.reverse(buffers)}, end_of_stream: :output]}, state}
  end

  defp put_time_information(state = %{output_caps: %{framerate: {framerate, 1}}}) do
    state
    |> Map.put(:frame_interval, Time.second() / framerate)
    |> Map.put(:timer, Time.seconds(0))
  end

  defp put_time_information(%{output_caps: %{}}), do: raise("framerate not supported")
  defp put_time_information(_), do: raise("output caps are required")

  defp increment_timer(state = %{timer: timer, frame_interval: interval}) do
    %{state | timer: timer + interval}
  end
end
