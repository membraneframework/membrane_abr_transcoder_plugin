if Mix.target() == :nvidia do
  defmodule ABRTranscoder.Backends.Nvidia do
    @moduledoc """
    ABRTranscoder backend implementation utilizing Nvidia T4 GPU card.
    """
    @behaviour ABRTranscoder.Backend

    use Unifex.Loader
    use TypedStruct

    typedstruct enforce: true do
    end

    @impl true
    def initialize_transcoder(
          %__MODULE__{},
          original_stream,
          target_streams
        ) do
      create(
        original_stream,
        target_streams
      )
    end
  end
end
