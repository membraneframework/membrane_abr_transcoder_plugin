defmodule ABRTranscoder.FrameGapInserter do
  @moduledoc """
  Membrane filter used for inserting timestamps gap at specified buffer positions.

  It is useful for testing the behavior of the transcoder when the input stream contains
  frame gaps so that to ensure the transcoded frames have proper timestamps.
  """
  use Membrane.Filter

  @type gap_t :: {frame_num :: non_neg_integer(), gap_size :: non_neg_integer()}

  def_options gap_positions: [
                spec: [gap_t()],
                default: [],
                description: """
                List of frame gaps that will be applied to the stream.
                """
              ],
              gap_size: [
                spec: Membrane.Time.t(),
                description: """
                The size of a single frame gap in membrane's time.
                """
              ]

  def_input_pad :input, accepted_format: _any
  def_output_pad :output, accepted_format: _any

  @impl true
  def handle_init(_ctx, opts) do
    opts
    |> Map.from_struct()
    |> Map.put(:offset, 0)
    |> Map.put(:total_frames, 0)
    |> then(&{[], &1})
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    %{
      total_frames: frame_num,
      offset: offset,
      gap_positions: gap_positions,
      gap_size: gap_size
    } = state

    offset =
      case List.keyfind(gap_positions, frame_num, 0) do
        {_frame_num, gap} -> offset + gap * gap_size
        nil -> offset
      end

    buffer = %Membrane.Buffer{buffer | dts: buffer.dts + offset, pts: buffer.pts + offset}

    state =
      state
      |> Map.update!(:total_frames, &(&1 + 1))
      |> Map.put(:offset, offset)

    {[buffer: {:output, buffer}], state}
  end
end
