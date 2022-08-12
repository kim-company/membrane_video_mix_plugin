defmodule Membrane.VideoMixer.Filters do
  def build_filters(%{width: width, height: height}) do
    %{
      1 => "[0:v]scale=-1:#{height}:force_original_aspect_ratio=decrease,setsar=1",
      2 =>
        "[0:v]scale=#{width}/3*2:#{height}:force_original_aspect_ratio=decrease,pad=#{width}/3*2+1:#{height}:-1:-1,setsar=1[l];[1:v]scale=-1:#{height}/3*2,crop=#{width}/3:ih:iw/3:0,pad=#{width}/3:#{height}:-1:-1,setsar=1[r];[l][r]hstack"
    }
  end

  def build_filters(_caps), do: raise("output caps are needed")
end
