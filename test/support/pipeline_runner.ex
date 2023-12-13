defmodule ABRTranscoder.PipelineRunner do
  @moduledoc false

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad

  alias ABRTranscoder.StreamParams
  alias Membrane.Pad
  alias Membrane.Testing

  @type gap_t :: {position :: non_neg_integer(), size :: pos_integer()}

  @spec sink_name(non_neg_integer()) :: atom()
  def sink_name(n), do: :"sink_#{n}"

  @spec run(
          struct(),
          String.t(),
          StreamParams.t(),
          [StreamParams.t()],
          [gap_t()],
          gap_size :: Membrane.Time.t()
        ) :: Testing.Pipeline.t()
  def run(
        backend,
        input_file,
        original_stream,
        target_streams,
        gap_positions \\ [],
        gap_size \\ Membrane.Time.milliseconds(16)
      ) do
    structure = [
      child(:source, %Membrane.File.Source{location: input_file})
      |> child(:demuxer, Membrane.FLV.Demuxer)
      |> via_out(Pad.ref(:video, 0))
      |> child(:frame_gap_inserter, %ABRTranscoder.FrameGapInserter{
        gap_positions: gap_positions,
        gap_size: gap_size
      })
      |> child(:tee, Membrane.Tee.Parallel)
      |> child(:abr_transcoder, %ABRTranscoder{
        original_stream: original_stream,
        target_streams: target_streams,
        backend: backend,
        on_successful_init: fn -> :ok end,
        on_frame_process_start: fn -> :ok end,
        on_frame_process_end: fn -> :ok end
      }),
      get_child(:tee)
      |> child({:parser, :source}, parser())
      |> child(:sink_source, Testing.Sink)
    ]

    sinks =
      for {_stream, idx} <- Enum.with_index(target_streams) do
        get_child(:abr_transcoder)
        |> via_out(Pad.ref(:output, idx))
        |> child({:parser, idx}, parser())
        |> child(sink_name(idx), Testing.Sink)
      end

    pipeline = Testing.Pipeline.start_link_supervised!(structure: structure ++ sinks)
    Testing.Pipeline.execute_actions(pipeline, playback: :playing)

    assert_pipeline_play(pipeline)

    for i <- 0..(Enum.count(target_streams) - 1) do
      sink = sink_name(i)
      assert_start_of_stream(pipeline, ^sink, :input, 5_000)
    end

    pipeline
  end

  defp parser() do
    %Membrane.H264.Parser{
      output_stream_structure: :avc3
    }
  end
end
