defmodule MembraneVideoMixPlugin.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_video_mix_plugin,
      version: "0.1.0",
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      compilers: [:unifex, :bundlex] ++ Mix.compilers(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:membrane_core, "~> 0.10.0"},
      {:membrane_raw_video_format, "~> 0.2.0"},
      {:bunch, "~> 1.3"},
      {:membrane_common_c, "~> 0.13.0"},
      {:unifex, "~> 1.0"},

      # testing
      {:membrane_file_plugin, "~> 0.12.0"},
      {:membrane_h264_ffmpeg_plugin, "~> 0.21.5"},
      {:membrane_framerate_converter_plugin, "~> 0.5.0"}
    ]
  end
end
