defmodule ABRTranscoder do
  @moduledoc """
  Adaptive bit rate transcoder.

  ### ABR Ladder
  The element works as an ABR ladder, meaning that given a source
  stream it scales it to lower resolutions (with potentially halved framerate)
  which is desired by ABR protocols such as HLS to serve lower resolution streams to
  clients with worse network conditions.

  A single ABR ladder works in the following way:
  - decode the source stream
  - perform multiple scaling operations
  - optionally reduce the framerate
  - encode each scaled stream separately

  ### Hardware acceleration
  Decoding/encoding/scaling operations combined are very computational demanding
  and it is hard to perform them in real-time (with a speed equal or higher to the pace of incoming source stream).

  Even if we could achieve real-time performance with a regular CPU the server would not be able to
  handle many of such workflows.

  To keep a decent performance (streams per server) we need to use hardware that is better suited than a regular CPU
  which leaves us with either GPUs or other specialized accelerated hardware (e.g. Xilinx U30 cards).
  """
  use Membrane.Filter

  require Logger

  alias Membrane.H264

  # The value below has been chosen empirically (based on xilinx transcoder).
  # It is a maximum value that has been observed for 60FPS (source) -> 30FPS (first target)
  # transition.
  @max_allowed_input_output_frames_offset 45

  @full_framerate 2

  def_input_pad :input,
    accepted_format: %H264{alignment: :au, stream_structure: :annexb}

  def_output_pad :output,
    availability: :on_request,
    accepted_format: %H264{alignment: :au, stream_structure: :annexb},
    options: [
      width: [
        spec: pos_integer() | nil,
        default: nil,
        description: """
        Width of the output video. Preserves the input width by default.
        """
      ],
      height: [
        spec: pos_integer() | nil,
        default: nil,
        description: """
        Height of the output video. Preserves the input height by default.
        """
      ],
      framerate: [
        spec: :full | :half,
        default: :full,
        description: """
        Output framerate - `full` preserves the input framerate,
        `half` reduces it twice.
        """
      ],
      bitrate: [
        spec: pos_integer() | nil,
        default: nil,
        description: """
        When set, the encoder tries to output the stream with specified bitrate.
        """
      ]
    ]

  def_options backend: [
                spec: module() | struct(),
                description: """
                Module or struct representing a transcoder backend and its configuration
                that should be used for initialization.

                The available backends are `ABRTranscoder.Backends.Nvidia`
                and `ABRTranscoder.Backends.U30`.
                """
              ],
              min_inter_frame_delay: [
                default: Membrane.Time.milliseconds(250),
                inspector: &Membrane.Time.pretty_duration/1,
                spec: Membrane.Time.t(),
                description: """
                If delay between input frames is bigger than this value,
                the transcoder won't reduce the framerate on the outputs
                with `framerate: :half`.
                """
              ],
              telemetry_callbacks: [
                spec: %{
                  on_successful_init: (() -> term()),
                  on_frame_process_start: (() -> term()),
                  on_frame_process_end: (() -> term())
                },
                default: %{},
                description: """
                Callbacks called on particular transcoder events.
                """
              ]

  defmodule StreamParams do
    @moduledoc false
    # A set of stream parameters.
    # Can refer to an input stream or the output ones.

    use TypedStruct

    typedstruct enforce: true do
      field :width, non_neg_integer()
      field :height, non_neg_integer()
      field :framerate, integer()
      field :bitrate, integer()
      field :pad, Pad.ref()
    end
  end

  defmodule StreamFrame do
    @moduledoc false
    # Stream frame targeted at given output pad (identified by id).

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
      field :min_inter_frame_delay, non_neg_integer()
      field :telemetry_callbacks, %{atom => function()}
      field :target_streams, [StreamParams.t()], default: []
      field :transcoder_ref, reference() | nil, default: nil
      field :last_dts, non_neg_integer() | nil, default: nil
      field :initialized_at, non_neg_integer(), default: nil
      field :first_frame_processed?, boolean(), default: false
      field :always_expect_output_frame?, boolean(), default: false
      field :expect_next_output_frame?, boolean(), default: false
      field :input_frames, non_neg_integer(), default: 0
      field :output_frames, non_neg_integer(), default: 0
      field :input_frames_with_gaps, non_neg_integer(), default: 0
      field :input_ptss, [non_neg_integer()], default: []
      field :initial_input_pts, non_neg_integer() | nil, default: nil
    end
  end

  @impl true
  def handle_init(_ctx, opts) do
    default_telemetry_callbacks = %{
      on_successful_init: fn -> :ok end,
      on_frame_process_start: fn -> :ok end,
      on_frame_process_end: fn -> :ok end
    }

    opts =
      opts
      |> Map.from_struct()
      |> Map.update!(:backend, fn backend ->
        if is_atom(backend), do: struct!(backend), else: backend
      end)
      |> Map.update!(:telemetry_callbacks, &Map.merge(default_telemetry_callbacks, &1))

    {[], struct!(State, opts)}
  end

  @impl true
  def handle_stream_format(:input, %H264{} = format, ctx, state) do
    %State{backend: %backend{} = backend_config} = state

    original_stream = %StreamParams{
      width: format.width,
      height: format.height,
      framerate: 2,
      bitrate: -1,
      pad: :input
    }

    target_streams =
      ctx.pads
      |> Map.values()
      |> Enum.filter(&(&1.direction == :output))
      |> Enum.map(
        &%StreamParams{
          width: &1.options.width || original_stream.width,
          height: &1.options.height || original_stream.height,
          framerate:
            if(&1.options.framerate == :half, do: div(@full_framerate, 2), else: @full_framerate),
          bitrate: &1.options.bitrate || -1,
          pad: &1.ref
        }
      )
      |> Enum.sort_by(&{&1.width, &1.height, &1.framerate}, :desc)

    state = %{state | target_streams: target_streams}
    state = assign_output_frames_expectations(state)

    start = System.monotonic_time(:millisecond)

    case backend.initialize_transcoder(
           backend_config,
           original_stream,
           target_streams
         ) do
      {:ok, transcoder_ref} ->
        stop = System.monotonic_time(:millisecond)
        Logger.info("Transcoder initialized in #{stop - start}ms")

        state.telemetry_callbacks.on_successful_init.()

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
          |> Enum.map(fn stream ->
            format = %H264{alignment: :au, width: stream.width, height: stream.height}
            {:stream_format, {stream.pad, format}}
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
          |> Enum.map(fn stream ->
            {:end_of_stream, stream.pad}
          end)

        {actions ++ eos, %State{state | transcoder_ref: nil}}

      {:error, reason} ->
        raise "Failed to flush the transcoder: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_buffer(:input, buffer, _context, state) do
    state.telemetry_callbacks.on_frame_process_start.()

    frames_gap = calc_frames_gap(buffer.dts, state)
    state = update_input_ptss(buffer.pts, frames_gap, state)

    state = %{
      state
      | input_frames: state.input_frames + 1,
        input_frames_with_gaps: state.input_frames_with_gaps + frames_gap + 1
    }

    %State{backend: %backend{}, transcoder_ref: ref} = state

    case backend.process(buffer.payload, frames_gap, ref) do
      {:ok, payloads_per_stream} ->
        state = increment_output_frames(payloads_per_stream, state)
        state = maybe_update_first_frame_processed(payloads_per_stream, state)

        maybe_log_empty_payloads_warning(payloads_per_stream, state)
        state = update_output_frame_expectations(payloads_per_stream, state)

        state.telemetry_callbacks.on_frame_process_end.()
        actions = handle_stream_payloads(payloads_per_stream, state)

        state = %{state | last_dts: buffer.dts}
        {actions, state}

      {:error, reason} ->
        raise "Failed to process buffer: #{inspect(reason)}"
    end
  end

  defp handle_stream_payloads(payloads_per_stream, state) do
    for %StreamFrame{id: id, payload: payload, pts: pts, dts: dts} <- payloads_per_stream do
      %StreamParams{framerate: framerate, pad: pad_ref} = Enum.at(state.target_streams, id)

      new_pts = get_corresponding_timestamp(pts * div(@full_framerate, framerate), state)
      new_dts = get_corresponding_timestamp(dts * div(@full_framerate, framerate), state)

      {:buffer, {pad_ref, %Membrane.Buffer{payload: payload, pts: new_pts, dts: new_dts}}}
    end
  end

  defp calc_frames_gap(_dts, %{last_dts: nil}) do
    0
  end

  defp calc_frames_gap(dts, state) do
    dts_diff = dts - state.last_dts

    if dts_diff > state.min_inter_frame_delay do
      max(round(dts_diff / state.min_inter_frame_delay) - 1, 0)
    else
      0
    end
  end

  defp assign_output_frames_expectations(state) do
    # When a first target steam has the same framerate as source we will always expect to match
    # input to output frame in 1:1 manner. When it is lower, it is expected to be 2:1 ratio and
    # we should expect every other frame.

    max_framerate = state.target_streams |> Enum.map(& &1.framerate) |> Enum.max()

    state
    |> Map.put(:always_expect_output_frame?, max_framerate == @full_framerate)
    |> Map.put(:expect_next_output_frame?, max_framerate == @full_framerate)
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

  # Stores PTS of an input frame in the ordered list
  # so that it could be matched to the corresponding
  # output frame. The list tail is cut off once a while
  # to prevent memory leak.
  defp update_input_ptss(pts, frames_gap, state) do
    initial_pts = state.initial_input_pts || pts
    input_pts = pts - initial_pts

    input_ptss =
      if rem(state.input_frames, @max_allowed_input_output_frames_offset * 2) == 0 do
        Enum.take(state.input_ptss, @max_allowed_input_output_frames_offset * 2)
      else
        state.input_ptss
      end

    {greater_ptss, lower_ptss} =
      Enum.split_while(input_ptss, fn {pts, _frames_no} -> pts > input_pts end)

    %{
      state
      | initial_input_pts: initial_pts,
        input_ptss: greater_ptss ++ [{input_pts, frames_gap + 1}] ++ lower_ptss
    }
  end

  # Finds the timestamp for the output frame
  # basing on a 'timestamp' returned by the backend.
  # Since the 'timestamp' returned by the backend is
  # actually an ordering number, we can use it to tell
  # which input frame's timestamp we should choose.
  defp get_corresponding_timestamp(timestamp, state) do
    state.input_ptss
    |> Enum.reduce_while(state.input_frames_with_gaps - 1, fn {pts, frames_no}, i ->
      if timestamp in (i - frames_no + 1)..i do
        {:halt, {:pts, pts}}
      else
        {:cont, i - frames_no}
      end
    end)
    |> then(fn {:pts, pts} -> pts end)
  end
end
