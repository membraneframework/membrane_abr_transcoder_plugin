# ABR Transcoder

An implementation of Membrane element responsible for ingesting
a single video stream and outputting multiple resolution in ABR (adaptive bitrate) fashion.

The main goal is to use hardware accelerated computing to process output streams
faster than real-time so the processing does not fall behind the source stream.

## Backends

`ABRTranscoder` module is supposed to be a generic API, seamless to use,
while the heavy lifting is done by an implementation of transcoder backend.

Currently available backends:

- `ABRTranscoder.Backends.U30` - implementation utilizing Xilinx U30 media accelerator (available via AWS VT1 instances)

## Installation

Backend implementations are highly dependent on the system they get installed in therefore
one needs to specify a particular `mix` target to enforce the backend compilation.

Targets per backend implementation:

- `xilinx` -> `ABRTranscoder.Backends.U30`

Once the the target gets specified the proper backend module should become available (given the compilation was successful).

To use the transcoder in `broadcast_engine` application just import the dependency and specify the proper target via `MIX_TARGET` env:

```elixir
def deps do
  [
    {:abr_transcoder, path: "../abr_transcoder"}
  ]
end
```
