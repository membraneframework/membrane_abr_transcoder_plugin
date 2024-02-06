defmodule Membrane.ABRTranscoder.Backends.Nvidia do
  @moduledoc """
  Membrane.ABRTranscoder backend implementation utilizing Nvidia T4 GPU card.

  To use it, set `MIX_TARGET` to `nvidia`.
  """
  use TypedStruct

  typedstruct enforce: true do
  end

  if Mix.target() == :nvidia do
    @behaviour Membrane.ABRTranscoder.Backend

    use Unifex.Loader

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

    @spec initialize() :: :ok | {:error, reason :: String.t()}
    def initialize() do
      if probe = System.find_executable("nvidia-modprobe") do
        case System.cmd(probe, []) do
          {_reusult, 0} -> :ok
          {_result, _code} -> {:error, "failed to run nvidia-modprobe"}
        end
      else
        {:error, "nvidia-modprobe not found"}
      end
    end
  end
end
