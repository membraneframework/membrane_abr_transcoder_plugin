defmodule Membrane.ABRTranscoder.TestHelpers do
  @moduledoc false
  defp assert_receive_from_entity(assertion, entity, pid, pattern, timeout, failure_message) do
    quote do
      import ExUnit.Assertions
      pid_value = unquote(pid)

      unquote(assertion)(
        {unquote(entity), ^pid_value, unquote(pattern)},
        unquote(timeout),
        unquote(failure_message)
      )
    end
  end

  defp assert_receive_from_pipeline(pid, pattern, timeout, failure_message \\ nil) do
    assert_receive_from_entity(
      :assert_receive,
      Membrane.Testing.Pipeline,
      pid,
      pattern,
      timeout,
      failure_message
    )
  end

  defmacro assert_receive_sink_buffer(pipeline, sink_name, pattern, timeout \\ 2_000) do
    assertion = &assert_receive_from_pipeline/3

    quote do
      unquote(
        assertion.(
          pipeline,
          {:handle_child_notification, {{:buffer, pattern}, sink_name}},
          timeout
        )
      )
    end
  end

  defmacro sink_buffer_match(pipeline, sink_name, pattern) do
    quote do
      {Membrane.Testing.Pipeline, unquote(pipeline),
       {:handle_child_notification, {{:buffer, unquote(pattern)}, unquote(sink_name)}}}
    end
  end

  defmacro sink_eos_match(pipeline, sink_name) do
    quote do
      {Membrane.Testing.Pipeline, unquote(pipeline),
       {:handle_element_end_of_stream, {unquote(sink_name), :input}}}
    end
  end

  defmacro assert_receive_end_of_stream(pipeline, sink_name, timeout \\ 2_000) do
    assertion = &assert_receive_from_pipeline/3

    quote do
      unquote(
        assertion.(
          pipeline,
          {:handle_element_end_of_stream, {sink_name, :input}},
          timeout
        )
      )
    end
  end
end
