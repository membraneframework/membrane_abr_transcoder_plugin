module Membrane.ABRTranscoder.Backends.U30

interface [NIF]

state_type "State"

type abr_stream_params :: %Membrane.ABRTranscoder.StreamParams{
  bitrate: int,
  width: int,
  height: int,
  framerate: int
}

type stream_frame :: %Membrane.ABRTranscoder.StreamFrame{
  id: uint,
  pts: int,
  dts: int,
  payload: payload,
}

spec initialize(devices :: int) :: (:ok :: label) | {:error :: label, reason :: string}

spec create(
  device_id :: int64,
  original_stream_params :: abr_stream_params,
  target_streams :: [abr_stream_params]
) :: {:ok :: label, state} | {:error :: label, reason :: string}

spec update_sps_and_pps(sps_and_pps :: payload, state) :: (:ok :: label) | {:error :: label, reason :: string}

spec process(payload, frames_gap :: int, state) ::
  {:ok :: label, [stream_frame]} | {:error :: label, reason :: string}


spec flush(state) :: {:ok :: label, [stream_frame]} | {:error :: label, reason :: string}

dirty :cpu, create: 3, process: 2, flush: 1
