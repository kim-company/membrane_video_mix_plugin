# MembraneVideoMixPlugin

Merge multiple video inputs to a single output using ffmpeg filters.
The mixer allows dynamic input quality switches and source addition-removal while running.

## Example

```elixir
defmodule Example do
  use Membrane.Pipeline

  @impl true
  def handle_init({file_1, file_2}) do
    children = [
      file_1: %Membrane.File.Source{location: file_1},
      file_2: %Membrane.File.Source{location: file_2},
      parser_1: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      parser_2: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      decoder_1: Membrane.H264.FFmpeg.Decoder,
      decoder_2: Membrane.H264.FFmpeg.Decoder,
      mixer: %Membrane.VideoMixer{
        output_caps: %Membrane.RawVideo{width: 1280, height: 720, pixel_format: :I420, framerate: {25, 1}, aligned: true}
      },
      encoder: Membrane.H264.FFmpeg.Encoder,
      sink: %Membrane.File.Sink{location: "output.h264"}
    ]

    links = [
      # input 1
      link(:file_1)
      |> to(:parser_1)
      |> to(:decoder_1)
      |> to(:mixer),
      # input 2
      link(:file_2)
      |> to(:parser_2)
      |> to(:decoder_2)
      |> to(:mixer),
      # mixer
      link(:mixer)
      |> to(:encoder)
      |> to(:sink)
    ]

    {{:ok, [spec: %ParentSpec{children: children, links: links}, playback: :playing]}, %{}}
  end
end
```

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `membrane_video_mix_plugin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_video_mix_plugin, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/membrane_video_mix_plugin>.