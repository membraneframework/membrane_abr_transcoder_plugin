if Mix.target() == :xilinx do
  defmodule ABRTranscoder.Backend.U30.FrameDroppingIntegrationTest do
    use ExUnit.Case, async: false

    import ABRTranscoder.TestHelpers

    alias ABRTranscoder.PipelineRunner
    alias ABRTranscoder.StreamParams

    @u30_frames_overhead 10
    @ms Membrane.Time.milliseconds(1)

    @gap_size_60_fps Membrane.Time.nanoseconds(16_666_667)

    setup ctx do
      options =
        ctx
        |> Map.to_list()
        |> Keyword.take([:duration, :keyframe_positions, :framerate, :bitrate])
        |> Keyword.put(:base_path, "/tmp")

      {:ok, video_path} = ABRTranscoder.VideoGenerator.generate_video(options)

      [video_path: video_path, backend: %ABRTranscoder.Backends.U30{device_id: 0}]
    end

    defp params_with_multiscaler_half_rate() do
      original_stream = %StreamParams{
        width: 1920,
        height: 1080,
        framerate: 60,
        bitrate: 6_000_000
      }

      target_streams = [
        %StreamParams{
          width: 1280,
          height: 720,
          framerate: 60,
          bitrate: 3_000_000
        },
        %StreamParams{
          width: 852,
          height: 480,
          framerate: 30,
          bitrate: 3_000_000
        }
      ]

      {original_stream, target_streams}
    end

    defp params_with_source_half_rate() do
      original_stream = %StreamParams{
        width: 1920,
        height: 1080,
        framerate: 60,
        bitrate: 6_000_000
      }

      target_streams = [
        %StreamParams{
          width: 1280,
          height: 720,
          framerate: 30,
          bitrate: 3_000_000
        }
      ]

      {original_stream, target_streams}
    end

    defp params_with_same_rate() do
      original_stream = %StreamParams{
        width: 1920,
        height: 1080,
        framerate: 60,
        bitrate: 6_000_000
      }

      target_streams = [
        %StreamParams{
          width: 1280,
          height: 720,
          framerate: 60,
          bitrate: 3_000_000
        }
      ]

      {original_stream, target_streams}
    end

    defp assert_buffers_matching(pipeline, ctx, total, source_stream, target_streams) do
      for actions <-
            buffers_matching_plan(
              total,
              source_stream,
              target_streams,
              ctx.keyframe_positions,
              ctx.gap_positions
            ) do
        buffers =
          for {:read_stream, sink, keyframe?} <- actions do
            assert_receive_sink_buffer(pipeline, ^sink, buffer, 5_000)

            if keyframe? do
              assert buffer.metadata.h264.key_frame?
            end

            buffer
          end

        dts = hd(buffers).dts

        for buffer <- buffers do
          assert_in_delta buffer.dts, dts, ctx.gap_size + @ms
        end
      end
    end

    defp buffers_matching_plan(
           total,
           source_stream,
           target_streams,
           keyframe_positions,
           gap_positions
         ) do
      Enum.map_reduce(0..total, %{source_frames: 0}, fn i, %{source_frames: source_frames} ->
        gap_present? = Enum.any?(gap_positions, fn {pos, _} -> pos == i end)

        keyframe? = Enum.member?(keyframe_positions, i)
        source_frame_at_odd_pos? = rem(source_frames, 2) == 1

        # when a source frame is at an odd position and a frame gap appears
        # it usually means that the frame will be repeated for lower framerate streams
        # (due to FPS halving dropping every other frame)
        source_frames =
          if gap_present? and source_frame_at_odd_pos? do
            source_frames + 1
          else
            source_frames
          end

        sink_actions =
          build_sink_actions(
            target_streams,
            source_stream,
            gap_present?,
            source_frame_at_odd_pos?,
            keyframe?
          )

        actions = [{:read_stream, :sink_source, keyframe?} | sink_actions]
        {actions, %{source_frames: source_frames + 1}}
      end)
      |> then(fn {actions, _ctx} -> actions end)
    end

    defp build_sink_actions(
           target_streams,
           source_stream,
           gap_present?,
           source_frame_at_odd_pos?,
           keyframe?
         ) do
      target_streams
      |> Enum.with_index()
      |> Enum.map(fn {stream, idx} ->
        sink = PipelineRunner.sink_name(idx)

        action =
          build_action(
            stream,
            source_stream,
            gap_present?,
            source_frame_at_odd_pos?,
            keyframe?,
            sink
          )

        action
      end)
    end

    defp build_action(
           stream,
           source_stream,
           gap_present?,
           source_frame_at_odd_pos?,
           keyframe?,
           sink
         ) do
      cond do
        stream.framerate == source_stream.framerate ->
          {:read_stream, sink, keyframe?}

        stream.framerate < source_stream.framerate and
            (gap_present? or not source_frame_at_odd_pos?) ->
          new_keyframe? =
            if gap_present? and source_frame_at_odd_pos? and keyframe?, do: true, else: keyframe?

          {:read_stream, sink, new_keyframe?}

        true ->
          nil
      end
    end

    defp assert_streams_ended(pipeline, target_streams) do
      assert_receive_end_of_stream(pipeline, :sink_source)

      for i <- 0..(Enum.count(target_streams) - 1) do
        sink = PipelineRunner.sink_name(i)
        assert_receive_end_of_stream(pipeline, ^sink)
      end
    end

    defp run_test_scenario(ctx, parameters) do
      parameters = List.wrap(parameters)

      for {original_stream, target_streams} <- parameters do
        pipeline =
          PipelineRunner.run(
            ctx.backend,
            ctx.video_path,
            original_stream,
            target_streams,
            ctx.gap_positions,
            ctx.gap_size
          )

        assert_buffers_matching(
          pipeline,
          ctx,
          600 - @u30_frames_overhead,
          original_stream,
          target_streams
        )

        assert_streams_ended(pipeline, target_streams)
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
    test "transcode h264 frames while taking into account existing frame gaps", ctx do
      run_test_scenario(ctx, params_with_multiscaler_half_rate())
    end

    @tag :tmp_dir
    @tag duration: 10
    @tag framerate: 60
    @tag bitrate: 6_000_000
    @tag keyframe_positions: [0, 1, 2, 3, 4, 5, 6, 120, 240]
    @tag gap_positions: [{1, 119}, {2, 70}, {3, 119}, {4, 99}, {5, 60}, {6, 100}]
    @tag gap_size: @gap_size_60_fps
    @tag timeout: 60_000
    test "keyframe-only continious stream", ctx do
      run_test_scenario(ctx, [
        params_with_multiscaler_half_rate(),
        params_with_source_half_rate(),
        params_with_same_rate()
      ])
    end
  end
end
