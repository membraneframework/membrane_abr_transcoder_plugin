defmodule Membrane.ABRTranscoder.Backends.U30 do
  @moduledoc """
  Membrane.ABRTranscoder backend implementation utilizing Xilinx U30 media accelerator cards.

  To use it, set `MIX_TARGET` to `xilinx`.
  """
  use TypedStruct

  typedstruct enforce: true do
    @typedoc """
    Options for initializing an ABR transcoder utilizing U30 backend.

    Fields:
    * `device_id` - the ID of U30 device which should be used for the ABR transcoder
    """

    field :device_id, non_neg_integer()
  end

  if Mix.target() == :xilinx do
    @behaviour Membrane.ABRTranscoder.Backend

    use Unifex.Loader

    @impl true
    def initialize_transcoder(
          %__MODULE__{device_id: device_id},
          original_stream,
          target_streams
        ) do
      create(
        device_id,
        original_stream,
        target_streams
      )
    end
  end
end
