defmodule ABRTranscoder.PipelineRunner do
  @moduledoc false

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad

  alias Membrane.Pad
  alias Membrane.Testing

  @type gap_t :: {position :: non_neg_integer(), size :: pos_integer()}

  @spec sink_name(non_neg_integer()) :: atom()
  def sink_name(n), do: :"sink_#{n}"

  @spec run(
          struct(),
          String.t(),
          Keyword.t(),
          [gap_t()],
          gap_size :: Membrane.Time.t(),
          min_inter_frame_delay :: Membrane.Time.t()
        ) :: Testing.Pipeline.t()
  def run(
        backend,
        input_file,
        target_streams,
        gap_positions \\ [],
        gap_size \\ Membrane.Time.milliseconds(16),
        min_inter_frame_delay \\ Membrane.Time.milliseconds(250)
      ) do
    structure = [
      child(:source, %Membrane.File.Source{location: input_file})
      |> child(:demuxer, Membrane.FLV.Demuxer)
      |> via_out(Pad.ref(:video, 0))
      |> child(:frame_gap_inserter, %ABRTranscoder.FrameGapInserter{
        gap_positions: gap_positions,
        gap_size: gap_size
      })
      |> child({:parser, :source}, %Membrane.H264.Parser{output_stream_structure: :annexb})
      |> child(:tee, Membrane.Tee.Parallel)
      |> child(:abr_transcoder, %ABRTranscoder{
        backend: backend,
        min_inter_frame_delay: min_inter_frame_delay
      }),
      get_child(:tee)
      |> child(:sink_source, Testing.Sink)
    ]

    sinks =
      for {stream, idx} <- Enum.with_index(target_streams) do
        get_child(:abr_transcoder)
        |> via_out(:output, options: stream)
        |> child({:parser, idx}, Membrane.H264.Parser)
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
end
