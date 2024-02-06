defmodule Membrane.ABRTranscoder.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_abr_transcoder_plugin,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      compilers: extra_compilers() ++ Mix.compilers(),
      deps: deps(),
      dialyzer: dialyzer(),
      docs: docs()
    ]
  end

  defp extra_compilers do
    case Mix.target() do
      :host -> []
      target when target in [:xilinx, :nvidia] -> [:unifex, :bundlex]
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:membrane_core, "~> 1.0"},
      {:unifex, "~> 1.1"},
      {:membrane_h264_format, "~> 0.6.1"},
      {:membrane_raw_video_format, "~> 0.3.0"},

      # dev dependencies
      {:typed_struct, "~> 0.3", runtime: false},
      {:credo, "~> 1.4", only: :dev, runtime: false},
      {:dialyxir, "~> 1.1", only: :dev, runtime: false},
      {:ex_doc, "~> 0.27", only: :dev, runtime: false},

      # test depenencies
      {:membrane_h264_plugin, "~> 0.9.0", only: :test},
      {:membrane_file_plugin, "~> 0.16.0", only: :test},
      {:membrane_flv_plugin, "~> 0.12.0", only: :test},
      {:membrane_tee_plugin, "~> 0.12.0", only: :test}
    ]
  end

  defp dialyzer() do
    opts = [
      flags: [:error_handling]
    ]

    if System.get_env("CI") == "true" do
      # Store PLTs in cacheable directory for CI
      [plt_local_path: "priv/plts", plt_core_path: "priv/plts"] ++ opts
    else
      opts
    end
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      formatters: ["html"]
    ]
  end
end
