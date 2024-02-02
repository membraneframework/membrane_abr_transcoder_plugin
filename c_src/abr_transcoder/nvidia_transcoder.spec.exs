module ABRTranscoder.Backends.Nvidia

interface [NIF]

state_type "State"

type abr_stream_params :: %ABRTranscoder.StreamParams{
  bitrate: int,
  width: int,
  height: int,
  framerate: int
}

type stream_frame :: %ABRTranscoder.StreamFrame{
  id: uint,
  pts: int,
  dts: int,
  payload: payload,
}

spec create(
  original_stream_params :: abr_stream_params,
  target_streams :: [abr_stream_params]
) :: {:ok :: label, state} | {:error :: label, reason :: string}

spec update_sps_and_pps(sps_and_pps :: payload, state) :: (:ok :: label) | {:error :: label, reason :: string}

spec process(payload, frames_gap :: int, state) ::
  {:ok :: label, [stream_frame]} | {:error :: label, reason :: string}


spec flush(state) :: {:ok :: label, [stream_frame]} | {:error :: label, reason :: string}

dirty :io,
  create: 2

dirty :cpu,
  process: 3,
  update_sps_and_pps: 2,
  flush: 1
