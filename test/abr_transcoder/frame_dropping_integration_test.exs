defmodule ABRTranscoder.FrameDroppingIntegrationTest do
  use ExUnit.Case, async: false

  import ABRTranscoder.TestHelpers

  alias ABRTranscoder.PipelineRunner

  @ms Membrane.Time.milliseconds(1)

  @gap_size_60_fps Membrane.Time.nanoseconds(16_666_667)

  @moduletag :integration

  @backend (case Mix.target() do
              :xilinx -> struct!(ABRTranscoder.Backends.U30, device_id: 0)
              :nvidia -> struct!(ABRTranscoder.Backends.Nvidia, [])
            end)

  setup ctx do
    options =
      ctx
      |> Map.to_list()
      |> Keyword.take([:duration, :keyframe_positions, :framerate, :bitrate])
      |> Keyword.put(:base_path, ctx.tmp_dir)

    {:ok, video_path} = ABRTranscoder.VideoGenerator.generate_video(options)

    [video_path: video_path, backend: @backend]
  end

  defp params_with_multiscaler_half_rate() do
    original_stream = %{
      width: 1920,
      height: 1080,
      framerate: 60,
      bitrate: 6_000_000
    }

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

    {original_stream, target_streams}
  end

  defp params_with_source_half_rate() do
    original_stream = %{
      width: 1920,
      height: 1080,
      framerate: 60,
      bitrate: 6_000_000
    }

    target_streams = [
      [
        width: 1280,
        height: 720,
        framerate: :half,
        bitrate: 3_000_000
      ]
    ]

    {original_stream, target_streams}
  end

  defp params_with_same_rate() do
    original_stream = %{
      width: 1920,
      height: 1080,
      framerate: 60,
      bitrate: 6_000_000
    }

    target_streams = [
      [
        width: 1280,
        height: 720,
        framerate: :full,
        bitrate: 3_000_000
      ]
    ]

    {original_stream, target_streams}
  end

  defp assert_buffers_matching_by_gop(pipeline, ctx, target_streams) do
    source_gops =
      pipeline
      |> drain_sink_buffers(:sink_source)
      |> split_buffers_by_gop()

    target_streams_gops =
      for i <- 0..(Enum.count(target_streams) - 1) do
        pipeline
        |> drain_sink_buffers(PipelineRunner.sink_name(i))
        |> split_buffers_by_gop()
      end

    for target_stream_gops <- target_streams_gops do
      source_gops
      |> Enum.zip(target_stream_gops)
      |> Enum.each(fn {source_gop, target_gop} ->
        source_buffer = hd(source_gop)
        target_buffer = hd(target_gop)

        assert_in_delta source_buffer.dts, target_buffer.dts, 2 * ctx.gap_size + @ms
      end)
    end
  end

  defp drain_sink_buffers(pipeline, sink_name, acc \\ []) do
    receive do
      sink_buffer_match(^pipeline, ^sink_name, buffer) ->
        buffer = %Membrane.Buffer{buffer | payload: <<>>}
        drain_sink_buffers(pipeline, sink_name, [buffer | acc])

      sink_eos_match(^pipeline, ^sink_name) ->
        Enum.reverse(acc)
    after
      5_000 ->
        raise "Sink draining timed out"
    end
  end

  defp split_buffers_by_gop(buffers) do
    Enum.chunk_while(
      buffers,
      [],
      fn buffer, acc ->
        case acc do
          [] ->
            {:cont, [buffer | acc]}

          gop ->
            if buffer.metadata.h264.key_frame? do
              {:cont, Enum.reverse(gop), [buffer]}
            else
              {:cont, [buffer | gop]}
            end
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
  end

  defp run_test_scenario(ctx, parameters, opts \\ []) do
    parameters = List.wrap(parameters)

    for {_original_stream, target_streams} <- parameters do
      pipeline =
        PipelineRunner.run(
          ctx.backend,
          ctx.video_path,
          target_streams,
          ctx.gap_positions,
          ctx.gap_size,
          1.1 * Membrane.Time.seconds(1) / 60
        )

      case Keyword.get(opts, :buffer_match_strategy, :match_buffers_by_gop) do
        :match_buffers_by_gop ->
          assert_buffers_matching_by_gop(
            pipeline,
            ctx,
            target_streams
          )
      end

      Membrane.Pipeline.terminate(pipeline)
    end
  end

  @tag :tmp_dir
  @tag duration: 10
  @tag framerate: 60
  @tag bitrate: 6_000_000
  @tag keyframe_positions: [0, 120, 240, 360, 479, 538, 560]
  @tag gap_positions: [{4, 1}, {5, 1}, {7, 1}, {8, 1}, {11, 1}, {20, 50}]
  @tag gap_size: @gap_size_60_fps
  @tag timeout: 60_000
  test "dense frame dropping", ctx do
    run_test_scenario(ctx, [
      params_with_multiscaler_half_rate(),
      params_with_source_half_rate(),
      params_with_same_rate()
    ])
  end

  @tag :tmp_dir
  @tag duration: 10
  @tag framerate: 60
  @tag bitrate: 6_000_000
  @tag keyframe_positions: [0, 120, 240, 359, 479, 538, 560]
  @tag gap_positions: [{3, 3}, {4, 119}, {200, 1}, {202, 1}]
  @tag gap_size: @gap_size_60_fps
  @tag timeout: 60_000
  @tag run: true
  test "transcode h264 frames while taking into account existing frame gaps", ctx do
    run_test_scenario(ctx, params_with_multiscaler_half_rate())
  end

  @tag :tmp_dir
  @tag duration: 10
  @tag framerate: 60
  @tag bitrate: 6_000_000
  @tag keyframe_positions: [0, 1, 2, 3, 4, 5, 6, 120, 240, 360, 480, 560]
  @tag gap_positions: [{1, 119}, {2, 70}, {3, 119}, {4, 99}, {5, 60}, {6, 100}]
  @tag gap_size: @gap_size_60_fps
  @tag timeout: 60_000
  @tag :target
  test "keyframe-only continious stream", ctx do
    run_test_scenario(ctx, [
      params_with_multiscaler_half_rate(),
      params_with_source_half_rate(),
      params_with_same_rate()
    ])
  end

  @tag :tmp_dir
  @tag duration: 10
  @tag framerate: 60
  @tag bitrate: 6_000_000
  @tag keyframe_positions: Enum.to_list(0..8) ++ [120, 240, 360, 480, 560]
  @tag gap_positions: [{1, 3}, {2, 3}, {3, 3}, {4, 3}, {5, 3}, {6, 3}, {7, 3}, {8, 3}]
  @tag gap_size: @gap_size_60_fps
  @tag timeout: 60_000
  test "regression case where a keyframe gets requested twitce", ctx do
    run_test_scenario(ctx, [
      params_with_source_half_rate()
    ])
  end
end
