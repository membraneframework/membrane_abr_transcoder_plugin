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

  alias Membrane.H264

  def_input_pad :input,
    demand_mode: :auto,
    accepted_format: %H264{alignment: :au, stream_structure: :annexb}

  def_output_pad :output,
    demand_mode: :auto,
    availability: :on_request,
    accepted_format: %H264{alignment: :au, stream_structure: :annexb}

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
                spec: (-> term()),
                description:
                  "Callback that should be triggered on successful transcoder initialization"
              ],
              on_frame_process_start: [
                spec: (-> term()),
                description:
                  "Callback that should be triggered just before the start of frame processing"
              ],
              on_frame_process_end: [
                spec: (-> term()),
                description: "Callback that should be triggered right after the frame processing"
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
      field :on_frame_process_start, function()
      field :on_frame_process_end, function()
      field :initialized_at, non_neg_integer(), default: nil
      field :first_frame_processed?, boolean(), default: false
      field :always_expect_output_frame?, boolean()
      field :expect_next_output_frame?, boolean()
      field :input_frames, non_neg_integer(), default: 0
      field :output_frames, non_neg_integer(), default: 0
    end
  end

  @impl true
  def handle_init(_ctx, opts) do
    :ok = verify_streams(opts)

    opts
    |> Map.from_struct()
    |> assign_output_frames_expectations()
    |> then(&{[], struct!(State, &1)})
  end

  @impl true
  def handle_stream_format(:input, %H264{}, ctx, state) do
    %State{
      backend: %backend{} = backend_config,
      original_stream: original_stream,
      target_streams: target_streams
    } = state

    start = System.monotonic_time(:millisecond)

    case backend.initialize_transcoder(
           backend_config,
           original_stream,
           target_streams
         ) do
      {:ok, transcoder_ref} ->
        stop = System.monotonic_time(:millisecond)
        Logger.info("Transcoder initialized in #{stop - start}ms")

        state.on_successful_init.()

        Membrane.ResourceGuard.register(ctx.resource_guard, fn ->
          # this flush will only take effect on pipeline's non-normal shutdown
          backend.flush(transcoder_ref)
        end)

        state = %State{
          state
          | transcoder_ref: transcoder_ref,
            initialized_at: System.monotonic_time()
        }

        actions =
          state.target_streams
          |> Enum.with_index()
          |> Enum.map(fn {stream, idx} ->
            format = %H264{alignment: :au, width: stream.width, height: stream.height}
            {:stream_format, {Pad.ref(:output, idx), format}}
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
        for idx <- 0..(length(state.target_streams) - 1) do
          frames = Enum.count(payloads_per_stream, &(&1.id == idx))

          "target_#{idx} = #{frames}"
        end
        |> Enum.join(", ")
        |> then(&Logger.info("Flushing frames: #{&1}"))

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
    state.on_frame_process_start.()

    state = %{state | input_frames: state.input_frames + 1}

    payload = to_annex_b(buffer.payload, [])

    case backend.process(payload, state.next_frames_gap, ref) do
      {:ok, payloads_per_stream} ->
        state = increment_output_frames(payloads_per_stream, state)
        state = maybe_update_first_frame_processed(payloads_per_stream, state)

        maybe_log_empty_payloads_warning(payloads_per_stream, state)
        state = update_output_frame_expectations(payloads_per_stream, state)

        state.on_frame_process_end.()
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

  # NOTE: first target stream has the highest framerate among all target streams
  # thanks to verify_streams/1
  defp assign_output_frames_expectations(
         %{original_stream: og, target_streams: [ts | _rest]} = state
       ) do
    # When a first target steam has the same framerate as source we will always expect to match
    # input to output frame in 1:1 manner. When it is lower, it is expected to be 2:1 ratio and
    # we should expect every other frame.
    state
    |> Map.put(:always_expect_output_frame?, ts.framerate >= og.framerate)
    |> Map.put(:expect_next_output_frame?, ts.framerate >= og.framerate)
  end

  defp increment_output_frames(payloads, state) do
    first_stream_frames = Enum.count(payloads, &(&1.id == 0))

    %{state | output_frames: state.output_frames + first_stream_frames}
  end

  defp maybe_update_first_frame_processed(payloads, %State{first_frame_processed?: false} = state)
       when payloads != [] do
    now = System.monotonic_time()

    frames_offset =
      if state.always_expect_output_frame? do
        state.input_frames - state.output_frames
      else
        state.input_frames - 2 * state.output_frames
      end

    Logger.info(
      "First frame emitted after #{System.convert_time_unit(now - state.initialized_at, :native, :millisecond)}ms. Initial frames offset = #{frames_offset}."
    )

    %State{state | first_frame_processed?: true}
  end

  defp maybe_update_first_frame_processed(_payloads, state), do: state

  defp maybe_log_empty_payloads_warning(_payloads, state) when not state.first_frame_processed?,
    do: :ok

  defp maybe_log_empty_payloads_warning([], state)
       when state.always_expect_output_frame? or
              state.expect_next_output_frame? do
    log_empty_payloads_warning(state)
  end

  defp maybe_log_empty_payloads_warning(_payloads, _state), do: :ok

  defp update_output_frame_expectations([], state) when not state.expect_next_output_frame? do
    %{state | expect_next_output_frame?: true}
  end

  defp update_output_frame_expectations(_payloads, state)
       when not state.always_expect_output_frame? do
    %{state | expect_next_output_frame?: false}
  end

  defp update_output_frame_expectations(_payloads, state), do: state

  # The value below has been chosen empirically (based on xilinx transcoder).
  # It is a maximum value that has been observed for 60FPS (source) -> 30FPS (first target)
  # transition.
  @max_allowed_input_output_frames_offset 45
  defp log_empty_payloads_warning(state) do
    output_frames =
      if state.always_expect_output_frame? do
        state.output_frames
      else
        # we are expecting every other frame so to check for the allowed offset
        # multiply it by 2
        state.output_frames * 2
      end

    if state.input_frames - output_frames > @max_allowed_input_output_frames_offset do
      Logger.warning(
        "Unexpected empty transcoder result: input_frames = #{state.input_frames}, output_frames = #{output_frames}"
      )
    end

    :ok
  end

  defp to_annex_b(<<length::32, data::binary-size(length), rest::binary>>, acc),
    do: to_annex_b(rest, [acc, [<<0, 0, 1>>, data]])

  defp to_annex_b(<<>>, acc), do: IO.iodata_to_binary(acc)
end
