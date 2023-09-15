defmodule ABRTranscoder.Backend do
  @moduledoc """
  Base behaviour for all abr transcoder backends.
  """

  alias ABRTranscoder.{StreamFrame, StreamParams}

  @doc """
  A callback initializing a native instance of transcoder.
  """
  @callback initialize_transcoder(
              config :: struct(),
              source_stream :: StreamParams.t(),
              target_streams :: [StreamParams.t()]
            ) :: {:ok, reference()} | {:error, reason :: any()}

  @doc """
  A callback updating transcoder's decoder sps and pps values.
  """
  @callback update_sps_and_pps(sps_and_pps :: binary(), transcoder :: reference()) ::
              :ok | {:error, reason :: any()}

  @doc """
  Callback used for passing a video payload to the native transcoder and getting back transcoded payloads for each previously defined resolution.
  """
  @callback process(
              payload :: binary(),
              frames_gap :: non_neg_integer(),
              transcoder :: reference()
            ) ::
              {:ok, [StreamFrame.t()]} | {:error, reason :: any()}

  @doc """
  Callback used for flushing the transcoder once the broadcast ended.

  The flush function is not expected to return any remaining frames, its main purpose
  is to properly flush native transcoders to avoid any warnings.
  """
  @callback flush(transcoder :: reference()) ::
              {:ok, [StreamFrame.t()]} | {:error, reason :: any()}
end
