defmodule Jido.Harness.StructuredOutput.Stream do
  @moduledoc false

  alias Jido.Harness.{Adapters.Helpers, Event, JSONSchema, StructuredOutput}
  alias Jido.Harness.StructuredOutput.WorkspaceGuard

  @end_of_stream {:jido_harness, :structured_output_end}

  @doc false
  @spec wrap(Enumerable.t(), StructuredOutput.t(), pid()) :: Enumerable.t()
  def wrap(stream, %StructuredOutput{} = output, guard) when is_pid(guard) do
    stream
    |> Stream.concat([@end_of_stream])
    |> Stream.transform(
      fn -> %{output: nil, output_count: 0, failure: nil, terminal?: false} end,
      &transform(&1, &2, output),
      fn _state -> WorkspaceGuard.close(guard) end
    )
  end

  defp transform(@end_of_stream, %{terminal?: false} = state, _output) do
    {[failure_event(:missing_terminal_result)], %{state | terminal?: true}}
  end

  defp transform(@end_of_stream, state, _output), do: {[], state}

  defp transform(%Event{type: :output_text_delta}, state, _output), do: {[], state}

  defp transform(%Event{type: :output_text_final, payload: payload}, state, output) do
    text = payload["text"]
    count = state.output_count + 1

    state =
      cond do
        count > 1 -> %{state | output_count: count, failure: :duplicate_terminal_output}
        not is_binary(text) -> %{state | output_count: count, failure: :missing_terminal_output}
        byte_size(text) > output.max_output_bytes -> %{state | output_count: count, failure: :terminal_output_too_large}
        true -> %{state | output_count: count, output: text}
      end

    {[], state}
  end

  defp transform(%Event{type: :run_completed} = terminal, state, output) do
    {events, state} = complete(state, terminal, output)
    {events, %{state | terminal?: true}}
  end

  defp transform(%Event{type: :run_failed}, state, _output) do
    {[failure_event(:provider_execution_failed)], %{state | terminal?: true}}
  end

  defp transform(%Event{type: :run_cancelled}, state, _output) do
    event = Helpers.event(:codex, :run_cancelled, nil, %{"reason" => "cancelled"})
    {[event], %{state | terminal?: true}}
  end

  defp transform(%Event{type: :usage} = event, state, _output),
    do: {[%{event | provider_session_id: nil, raw: nil}], state}

  defp transform(%Event{type: type} = event, state, _output) when type in [:turn_started, :turn_completed],
    do: {[%{event | provider_session_id: nil, raw: nil}], state}

  defp transform(%Event{}, state, _output), do: {[], state}

  defp complete(%{failure: failure} = state, _terminal, _output) when is_atom(failure) and not is_nil(failure),
    do: {[failure_event(failure)], state}

  defp complete(%{output_count: count} = state, _terminal, _output) when count != 1,
    do: {[failure_event(:missing_terminal_output)], state}

  defp complete(state, terminal, output) do
    with {:ok, value} <- Jason.decode(state.output),
         :ok <- JSONSchema.validate(value, output.schema) do
      final = Helpers.event(:codex, :output_text_final, nil, %{"text" => state.output})

      structured =
        Helpers.event(:codex, :structured_output, nil, %{
          "schema_id" => output.schema_id,
          "value" => value
        })

      {[final, structured, %{terminal | provider_session_id: nil, raw: nil}], state}
    else
      {:error, %Jido.Harness.Error{details: %{failure_kind: kind}}} ->
        {[failure_event(kind)], state}

      {:error, _decode_error} ->
        {[failure_event(:malformed_terminal_json)], state}
    end
  end

  defp failure_event(kind, provider_session_id \\ nil) do
    Helpers.event(:codex, :run_failed, provider_session_id, %{
      "error" => "structured-output validation failed",
      "failure_kind" => Atom.to_string(kind)
    })
  end
end
