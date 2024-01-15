# This example downloads a video via http, downscales it to two resolutions
# and saves outputs to files.

Mix.install([
  {:abr_transcoder, path: "."},
  :membrane_file_plugin,
  :membrane_hackney_plugin,
  :membrane_h264_plugin,
  :membrane_mp4_plugin
])

defmodule Example do
  import Membrane.ChildrenSpec
  alias Membrane.RCPipeline

  def run() do
    pipeline = RCPipeline.start_link!()

    RCPipeline.exec_actions(pipeline,
      spec: [
        child(%Membrane.Hackney.Source{
          location: "https://membraneframework.github.io/static/samples/ffmpeg-testsrc.h264",
          hackney_opts: [follow_redirect: true]
        })
        |> child(%Membrane.H264.Parser{generate_best_effort_timestamps: %{framerate: {30, 1}}})
        |> child(:transcoder, %ABRTranscoder{backend: ABRTranscoder.Backends.Nvidia}),
        output_spec(854, 480),
        output_spec(640, 360)
      ]
    )
  end

  defp output_spec(width, height) do
    get_child(:transcoder)
    |> via_out(:output, options: [width: width, height: height])
    |> child(%Membrane.H264.Parser{output_stream_structure: :avc1})
    |> child(Membrane.MP4.Muxer.ISOM)
    |> child(%Membrane.File.Sink{location: "out#{height}p.mp4"})
  end
end

Example.run()
Process.sleep(:infinity)
