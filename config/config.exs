import Config

config :logger, :console, metadata: [:module]

if Mix.target() == :xilinx and config_env() == :test do
  config :abr_transcoder, :initialize_u30, true
end
