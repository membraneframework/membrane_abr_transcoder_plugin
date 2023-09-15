defmodule ABRTranscoder do
  @moduledoc """
  Implementation of ABR (adaptive bit rate) transcoder.

  ## ABR Ladder
  The element works as a ABR ladder, meaning that given a source
  stream it scales it to lower resolutions (with potentially halved framerate)
  which is desired by ABR protocols such as HLS to serve lower resolution streams to
  clients with worse network conditions.

  A single ABR ladder works in the following way:
  - decode the source stream
  - perform multiple scaling operations
  - optionally reduce the framerate
  - encode each scaled stream separately

  ## Hardware acceleration
  Decoding/encoding/scaling operations combined are very computational demanding
  and it is hard to perform them in real-time (with a speed equal or higher to the pace of incoming source stream).

  Even if we could achieve real-time performance with a regular CPU the server would not be able to
  handle many of such workflows.

  To keep a decent performance (streams per server) we need to use hardware that is better suited than a regular CPU
  which leaves us with either GPUs or other specialized accelerated hardware (e.g. Xilinx U30 cards).

  ## Transcoder backends
  Each backend implementation should follow the `#{__MODULE__.Backend}` behaviour.
  """
  use Membrane.Filter

  require Logger

  def_input_pad :input,
    demand_mode: :auto,
    demand_unit: :buffers,
    accepted_format: _any

  def_output_pad :output,
    demand_mode: :auto,
    availability: :on_request,
    accepted_format: %Membrane.H264.RemoteStream{}

  def_options original_stream: [
                spec: __MODULE__.StreamParams.t(),
                description: "Parameters of the original H264 stream"
              ],
              target_streams: [
                spec: list(__MODULE__.StreamParams.t()),
                description: """
                List of parameters of target ABR streams. The order passed with this parameter
                is used as 0-based indexes for the output pads.
                """
              ],
              backend: [
                spec: struct(),
                description: """
                Struct representing a transcoder backend and its configuration
                that should be used for initialization
                """
              ],
              on_successful_init: [
                spec: (() -> term()),
                description:
                  "Callback that should be triggered on successful transcoder initialization"
              ],
              on_frame_process: [
                spec: (() -> term()),
                description: "Callback that should be triggered afterframe processing"
              ]

  defmodule StreamParams do
    @moduledoc """
    A set of stream parameters.

    Can refer to an input stream or the output ones.
    """
    use TypedStruct

    typedstruct enforce: true do
      field :width, non_neg_integer()
      field :height, non_neg_integer()
      field :framerate, non_neg_integer()
      field :bitrate, non_neg_integer()
    end
  end

  defmodule StreamFrame do
    @moduledoc """
    Stream frame targeted at given output pad (identified by id).
    """
    use TypedStruct

    typedstruct enforce: true do
      field :id, non_neg_integer()
      field :payload, binary()
      field :pts, non_neg_integer()
      field :dts, non_neg_integer()
    end
  end

  defmodule State do
    @moduledoc false
    use TypedStruct

    typedstruct enforce: true do
      field :backend, struct()
      field :original_stream, StreamParams.t()
      field :target_streams, [StreamParams.t()]
      field :transcoder_ref, reference() | nil, default: nil
      field :next_frames_gap, non_neg_integer(), default: 0
      field :on_successful_init, function()
      field :on_frame_process, function()
    end
  end

  @impl true
  def handle_init(_ctx, opts) do
    Logger.metadata(module: __MODULE__)

    :ok = verify_streams(opts)

    {[], struct!(State, Map.from_struct(opts))}
  end

  @impl true
  def handle_stream_format(
        :input,
        %Membrane.H264.RemoteStream{alignment: alignment, decoder_configuration_record: dcr},
        ctx,
        state
      ) do
    %State{
      backend: %backend{} = backend_config,
      original_stream: original_stream,
      target_streams: target_streams
    } = state

    unless dcr do
      raise "Empty decoder configuration record"
    end

    {:ok, %{sps: sps, pps: pps}} = Membrane.H264.Parser.DecoderConfigurationRecord.parse(dcr)

    sps_and_pps = Enum.map_join(sps ++ pps, &(<<0, 0, 1>> <> &1))

    case backend.initialize_transcoder(
           backend_config,
           original_stream,
           target_streams
         ) do
      {:ok, transcoder_ref} ->
        state.on_successful_init.()
        backend.update_sps_and_pps(sps_and_pps, transcoder_ref)

        Membrane.ResourceGuard.register(ctx.resource_guard, fn ->
          # this flush will only take effect on pipeline's non-normal shutdown
          backend.flush(transcoder_ref)
        end)

        state = %State{state | transcoder_ref: transcoder_ref}

        actions =
          state.target_streams
          |> Enum.with_index()
          |> Enum.map(fn {_stream, idx} ->
            {:stream_format,
             {Pad.ref(:output, idx), %Membrane.H264.RemoteStream{alignment: alignment}}}
          end)

        {actions, state}

      {:error, reason} ->
        Logger.error("Failed to initialize the transcoder: #{inspect(reason)}")
        {[terminate: {:shutdown, {:failed_to_allocate_transcoder, reason}}], state}
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{backend: %backend{}, transcoder_ref: ref} = state) do
    case backend.flush(ref) do
      {:ok, payloads_per_stream} ->
        actions = handle_stream_payloads(payloads_per_stream, state)

        eos =
          state.target_streams
          |> Enum.with_index()
          |> Enum.map(fn {_stream, idx} ->
            {:end_of_stream, Pad.ref(:output, idx)}
          end)

        {actions ++ eos, %State{state | transcoder_ref: nil}}

      {:error, reason} ->
        raise "Failed to flush the transcoder: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_event(:input, %Common.MediaTransport.DroppedVideoFramesEvent{} = event, _ctx, state) do
    {[], %{state | next_frames_gap: state.next_frames_gap + event.frames}}
  end

  @impl true
  def handle_event(:input, event, _ctx, state) do
    {[forward: event], state}
  end

  @impl true
  def handle_process(
        :input,
        buffer,
        _context,
        %State{backend: %backend{}, transcoder_ref: ref} = state
      ) do
    case backend.process(buffer.payload, state.next_frames_gap, ref) do
      {:ok, payloads_per_stream} ->
        state.on_frame_process.()
        actions = handle_stream_payloads(payloads_per_stream, state)

        state = %{state | next_frames_gap: 0}

        {actions, state}

      {:error, reason} ->
        raise "Failed to process buffer: #{inspect(reason)}"
    end
  end

  defp handle_stream_payloads(payloads_per_stream, state) do
    for %StreamFrame{id: pad_id, payload: payload, pts: pts, dts: dts} <- payloads_per_stream do
      %StreamParams{framerate: framerate} = Enum.at(state.target_streams, pad_id)

      pts =
        div(
          pts * Membrane.Time.second(),
          framerate
        )

      dts =
        div(
          dts * Membrane.Time.second(),
          framerate
        )

      {:buffer,
       {Pad.ref(:output, pad_id), %Membrane.Buffer{payload: payload, pts: pts, dts: dts}}}
    end
  end

  defp verify_streams(opts) do
    opts.target_streams
    # credo:disable-for-next-line Credo.Check.Warning.UnusedEnumOperation
    |> Enum.reduce(opts.original_stream, fn stream, prev_stream ->
      if stream.height <= prev_stream.height and
           stream.width <= prev_stream.width and
           stream.framerate <= prev_stream.framerate do
        stream
      else
        raise "specified targets streams must be passed in decreasing parameters order"
      end
    end)

    :ok
  end
end
