ExUnit.start(capture_log: true)

if Application.get_env(:abr_transcoder, :initialize_u30) do
  :ok = ABRTranscoder.Backends.U30.initialize(2)
end
