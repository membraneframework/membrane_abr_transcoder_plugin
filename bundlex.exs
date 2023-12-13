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
            pkg_configs: ["libavcodec", "libavfilter", "libavutil", "libxma2api", "libxrm", "xvbm"],
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
            pkg_configs: ["libavcodec", "libavfilter", "libavutil"],
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
end
