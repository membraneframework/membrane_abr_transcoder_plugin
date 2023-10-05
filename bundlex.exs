defmodule BroadcastEngine.ABRTranscoder.BundlexProject do
  use Bundlex.Project

  def project() do
    [
      natives: natives()
    ]
  end

  defp natives() do
    case Mix.target() do
      :xilinx ->
        [
          u30_transcoder: [
            interface: :nif,
            sources: [
              "u30_transcoder.cpp",
              "execution_profiler.cpp",
              "xilinx/xilinx_decoding_pipeline.cpp",
              "xilinx/xilinx_multiscaling_pipeline.cpp",
              "xilinx/xilinx_encoding_pipeline.cpp",
              "xilinx/xilinx_timestamp_emitter.cpp"
            ],
            pkg_configs: [
              "libavcodec",
              "libavfilter",
              "libavutil",
              "libxma2api",
              "libxrm",
              "xvbm"
            ],
            preprocessor: Unifex,
            language: :cpp,
            compiler_flags: ["-std=c++17"]
          ]
        ]

      :nvidia ->
        [
          nvidia_transcoder: [
            interface: :nif,
            sources: [
              "nvidia_transcoder.cpp",
              "execution_profiler.cpp",
              "nvidia/nvidia_device_context.cpp",
              "nvidia/nvidia_decoding_pipeline.cpp",
              "nvidia/nvidia_multiscaling_pipeline.cpp",
              "nvidia/nvidia_encoding_pipeline.cpp",
              "nvidia/nvidia_timestamp_emitter.cpp"
            ],
            os_deps: [
              ffmpeg: [
                # {:precompiled, get_ffmpeg_url(), ["libavcodec", "libavfilter", "libavutil"]},
                {:pkg_config, ["libavcodec", "libavfilter", "libavutil"]}
              ]
            ],
            preprocessor: Unifex,
            language: :cpp,
            compiler_flags: [
              "-std=c++17",
              "-Ic_src/abr_transcoder/vendor"
            ]
          ]
        ]

      :host ->
        []
    end
  end

  defp get_ffmpeg_url() do
    membrane_precompiled_url_prefix =
      "https://github.com/membraneframework-precompiled/precompiled_ffmpeg/releases/latest/download/ffmpeg"

    case Bundlex.get_target() do
      %{architecture: "aarch64", os: "linux"} ->
        {:precompiled,
         "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n6.0-latest-linuxarm64-gpl-shared-6.0.tar.xz"}

      %{os: "linux"} ->
        "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n6.0-latest-linux64-gpl-shared-6.0.tar.xz"

      %{architecture: "x86_64", os: "darwin" <> _rest_of_os_name} ->
        "#{membrane_precompiled_url_prefix}_macos_intel.tar.gz"

      %{architecture: "aarch64", os: "darwin" <> _rest_of_os_name} ->
        "#{membrane_precompiled_url_prefix}_macos_arm.tar.gz"

      _other ->
        nil
    end
  end
end
