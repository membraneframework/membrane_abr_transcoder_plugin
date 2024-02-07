opts = if Mix.target() == :host, do: [exclude: :integration], else: []

ExUnit.start(opts ++ [capture_log: true])

if Application.get_env(:membrane_abr_transcoder_plugin, :initialize_u30) do
  :ok = Membrane.ABRTranscoder.Backends.U30.initialize(2)
end
