# Membrane ABR Transcoder

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_abr_transcoder_plugin.svg)](https://hex.pm/packages/membrane_abr_transcoder_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_abr_transcoder_plugin)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_abr_transcoder_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_abr_transcoder_plugin)

This plugin provides an ABR (adaptive bitrate) transcoder, that accepts an h.264 video and outputs multiple variants of it with different qualities.
The transcoder supports two backends: Nvidia and Xilinx. Using the Nvidia backend is recommended, as it has proven to be more stable.

Depending on the backend you choose, the transcoder requires Nvidia or Xilinx drivers to work.
Here's how to setup the Nvidia driver and use the plugin in Docker on a Debian host:
```bash
$ scripts/install_docker.sh # installs Docker
$ scripts/setup_nvidia.sh # installs Nvidia drivers and Nvidia Container Toolkit
$ scripts/build_nvidia.sh # builds the Docker image
$ scripts/run_nvidia.sh # runs the Docker container
```

In the container, you can run an example pipeline with `elixir example.exs`. Check the `example.exs` file for details.

## Copyright and License

Copyright 2020, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_abr_transcoder_plugin)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_abr_transcoder_plugin)

Licensed under the [Apache License, Version 2.0](LICENSE)
