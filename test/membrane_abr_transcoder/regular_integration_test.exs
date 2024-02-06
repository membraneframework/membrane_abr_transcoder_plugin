defmodule Membrane.ABRTranscoder.RegularIntegrationTest do
  use ExUnit.Case, async: false

  import Membrane.ABRTranscoder.TestHelpers
  import Membrane.ABRTranscoder.PipelineRunner, only: [sink_name: 1]

  require Membrane.Pad

  alias Membrane.ABRTranscoder.PipelineRunner

  defp assert_streams_ended(pipeline, target_streams) do
    assert_receive_end_of_stream(pipeline, :sink_source)

    for i <- 0..(Enum.count(target_streams) - 1) do
      sink = PipelineRunner.sink_name(i)
      assert_receive_end_of_stream(pipeline, ^sink)
    end

    Membrane.Pipeline.terminate(pipeline)
  end

  @u30_frames_overhead 10

  @moduletag :integration

  @backend (case Mix.target() do
              :xilinx -> struct!(Membrane.ABRTranscoder.Backends.U30, device_id: 0)
              :nvidia -> struct!(Membrane.ABRTranscoder.Backends.Nvidia, [])
            end)

  setup ctx do
    options =
      ctx
      |> Map.to_list()
      |> Keyword.take([:duration, :keyframe_positions, :framerate, :bitrate])
      |> Keyword.put(:base_path, "/tmp")

    {:ok, video_path} = Membrane.ABRTranscoder.VideoGenerator.generate_video(options)

    [video_path: video_path, backend: @backend]
  end

  @tag :tmp_dir
  @tag duration: 10
  @tag framerate: 30
  @tag width: 1920
  @tag height: 1080
  @tag bitrate: 6_000_000
  @tag keyframe_positions: [0, 60, 120, 180, 240, 300]
  @tag timeout: 10 * 60_000
  test "transcode stream where all renditions have the same framerate", ctx do
    target_streams = [
      [
        width: 1280,
        height: 720,
        framerate: :full,
        bitrate: 3_000_000
      ],
      [
        width: 852,
        height: 480,
        framerate: :full
      ]
    ]

    pipeline = PipelineRunner.run(ctx.backend, ctx.video_path, target_streams)

    for _i <- 0..(300 - 2) do
      assert_receive_sink_buffer(pipeline, :sink_source, source_buffer)
      sink = sink_name(0)
      assert_receive_sink_buffer(pipeline, ^sink, hd_buffer)
      sink = sink_name(1)
      assert_receive_sink_buffer(pipeline, ^sink, sd_buffer)

      if source_buffer.metadata.h264.key_frame? do
        assert hd_buffer.metadata.h264.key_frame?
        assert sd_buffer.metadata.h264.key_frame?

        assert source_buffer.dts == hd_buffer.dts
        assert source_buffer.dts == sd_buffer.dts
      end
    end

    assert_streams_ended(pipeline, target_streams)
  end

  @tag :tmp_dir
  @tag duration: 10
  @tag framerate: 60
  @tag width: 1920
  @tag height: 1080
  @tag bitrate: 6_000_000
  @tag keyframe_positions: [0, 120, 240, 360, 480, 600]
  @tag timeout: 10 * 60_000
  test "transcode stream where only source has higher framerate", ctx do
    target_streams = [
      [
        width: 1280,
        height: 720,
        framerate: :half,
        bitrate: 3_000_000
      ],
      [
        width: 852,
        height: 480,
        framerate: :half
      ]
    ]

    pipeline = PipelineRunner.run(ctx.backend, ctx.video_path, target_streams)

    for i <- 0..(600 - @u30_frames_overhead) do
      assert_receive_sink_buffer(pipeline, :sink_source, _source_buffer)

      if rem(i, 2) == 0 do
        # due to faster-than-real-time input processing we get a single lag when receiving EOF,
        # prevent that by putting bigger buffer receive timeout
        sink = sink_name(0)
        assert_receive_sink_buffer(pipeline, ^sink, _hd_buffer, 5_000)
        sink = sink_name(1)
        assert_receive_sink_buffer(pipeline, ^sink, _sd_buffer, 5_000)
      end
    end

    assert_streams_ended(pipeline, target_streams)
  end

  @tag :tmp_dir
  @tag duration: 10
  @tag framerate: 60
  @tag bitrate: 6_000_000
  @tag keyframe_positions: [0, 2, 60, 63, 120, 121, 180, 185, 200, 260, 320, 480, 540, 595]
  @tag timeout: 10 * 60_000
  test "transcode h264 frames while keeping the originial key frame positions", ctx do
    target_streams = [
      [
        width: 1280,
        height: 720,
        framerate: :full,
        bitrate: 3_000_000
      ],
      [
        width: 852,
        height: 480,
        framerate: :half,
        bitrate: 3_000_000
      ]
    ]

    pipeline = PipelineRunner.run(ctx.backend, ctx.video_path, target_streams)

    for i <- 0..(600 - @u30_frames_overhead) do
      assert_receive_sink_buffer(pipeline, :sink_source, source_buffer)
      sink = sink_name(0)
      assert_receive_sink_buffer(pipeline, ^sink, hd_buffer)

      if i in ctx.keyframe_positions do
        assert source_buffer.metadata.h264.key_frame?
        assert hd_buffer.metadata.h264.key_frame?

        assert_in_delta source_buffer.dts, hd_buffer.dts, Membrane.Time.milliseconds(17)
      end

      if rem(i, 2) == 0 do
        sink = sink_name(1)
        assert_receive_sink_buffer(pipeline, ^sink, sd_buffer)

        if (i - rem(i, 2)) in ctx.keyframe_positions do
          assert sd_buffer.metadata.h264.key_frame?
        end
      end
    end

    assert_streams_ended(pipeline, target_streams)
  end

  @tag :tmp_dir
  @tag duration: 10
  @tag width: 1920
  @tag height: 1080
  @tag framerate: 30
  @tag bitrate: 6_000_000
  @tag keyframe_positions: [0, 120, 240, 360, 480]
  @tag repeat_headers: false
  @tag timeout: 10 * 60_000
  test "transcode stream with non-repeating h264 headers", ctx do
    target_streams = [
      [
        width: 1280,
        height: 720,
        framerate: :full,
        bitrate: 3_000_000
      ],
      [
        width: 852,
        height: 480,
        framerate: :full,
        bitrate: 3_000_000
      ]
    ]

    pipeline = PipelineRunner.run(ctx.backend, ctx.video_path, target_streams)

    for _i <- 0..(300 - @u30_frames_overhead) do
      assert_receive_sink_buffer(pipeline, :sink_source, _source_buffer)

      sink = sink_name(0)
      assert_receive_sink_buffer(pipeline, ^sink, _hd_buffer)

      sink = sink_name(1)
      assert_receive_sink_buffer(pipeline, ^sink, _sd_buffer)
    end

    assert_streams_ended(pipeline, target_streams)
  end
end
