import Config

config :logger, :console, metadata: [:module]

if Mix.target() == :xilinx and config_env() == :test do
  config :membrane_abr_transcoder_plugin, :initialize_u30, true
end
