defmodule Jido.Harness.Adapters.CLIMapper.Grok do
  @moduledoc false

  alias Jido.Harness.Adapters.Helpers
  alias Jido.Harness.Event

  @doc "Maps one Grok streaming-json record to zero or more harness events."
  @spec map(term(), map() | nil) :: {[Event.t()], map()}
  def map(raw, state)

  def map(%{"type" => "thought", "data" => text} = raw, state) when is_binary(text) do
    mapped(maybe_text(:thinking_delta, text, raw), state)
  end

  def map(%{"type" => "text", "data" => text} = raw, state) when is_binary(text) do
    mapped(maybe_text(:output_text_delta, text, raw), state)
  end

  def map(%{"type" => "usage", "usage" => usage} = raw, state) when is_map(usage) do
    usage = normalize_usage(usage)
    {[usage_event(raw, usage)], Map.put(normalize_state(state), :last_usage, usage)}
  end

  def map(%{"type" => "tool_call"} = raw, state) do
    event =
      Helpers.event(
        :grok,
        :tool_call,
        session_id(raw),
        %{
          "name" => raw["toolName"] || raw["title"],
          "input" => raw["rawInput"] || %{},
          "call_id" => raw["toolCallId"]
        },
        raw
      )

    mapped([event], state)
  end

  def map(%{"type" => "tool_call_update", "status" => status} = raw, state)
      when status in ["completed", "failed", "error", "cancelled", "canceled"] do
    event =
      Helpers.event(
        :grok,
        :tool_result,
        session_id(raw),
        %{
          "output" => raw["rawOutput"] || raw["content"],
          "call_id" => raw["toolCallId"],
          "is_error" => status != "completed"
        },
        raw
      )

    mapped([event], state)
  end

  def map(%{"type" => "error"} = raw, state) do
    event = Helpers.event(:grok, :run_failed, session_id(raw), %{"error" => error_message(raw)}, raw)
    mapped([event], state)
  end

  def map(%{"type" => "end"} = raw, state) do
    {usage_events, state} = terminal_usage(raw, normalize_state(state))
    {usage_events ++ [terminal_event(raw)], state}
  end

  def map(raw, state) do
    event =
      Helpers.event(
        :grok,
        :provider_event,
        session_id(raw),
        %{"type" => event_type(raw), "mapped" => false},
        raw
      )

    mapped([event], state)
  end

  defp terminal_usage(%{"usage" => usage} = raw, state) when is_map(usage) do
    usage = normalize_usage(usage)
    duplicate? = usage == state.last_usage
    state = Map.put(state, :last_usage, usage)

    if duplicate? do
      {[], state}
    else
      {[usage_event(raw, usage)], state}
    end
  end

  defp terminal_usage(_raw, state), do: {[], state}

  defp terminal_event(%{"stopReason" => stop_reason} = raw)
       when stop_reason in ["cancelled", "canceled"] do
    Helpers.event(:grok, :run_cancelled, session_id(raw), end_payload(raw), raw)
  end

  defp terminal_event(%{"stopReason" => stop_reason} = raw) when stop_reason in ["error", "failed"] do
    payload = Map.put(end_payload(raw), "error", error_message(raw))
    Helpers.event(:grok, :run_failed, session_id(raw), payload, raw)
  end

  defp terminal_event(raw), do: Helpers.event(:grok, :run_completed, session_id(raw), end_payload(raw), raw)

  defp usage_event(raw, usage), do: Helpers.event(:grok, :usage, session_id(raw), usage, raw)

  defp normalize_usage(usage) do
    Map.put_new_lazy(usage, "total_tokens", fn ->
      ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
      |> Enum.map(&numeric_value(usage[&1]))
      |> Enum.sum()
    end)
  end

  defp end_payload(raw) do
    [
      {"stop_reason", raw["stopReason"]},
      {"request_id", raw["requestId"]},
      {"num_turns", raw["num_turns"]},
      {"cost_usd", raw["total_cost_usd"]}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp error_message(raw) do
    case raw["message"] || raw["error"] || raw["data"] do
      value when is_binary(value) and value != "" -> value
      nil -> "Grok failed"
      value -> inspect(value)
    end
  end

  defp numeric_value(value) when is_number(value), do: value
  defp numeric_value(_value), do: 0
  defp mapped(events, state), do: {events, normalize_state(state)}
  defp normalize_state(state) when is_map(state), do: Map.put_new(state, :last_usage, nil)
  defp normalize_state(_state), do: %{last_usage: nil}
  defp maybe_text(_type, "", _raw), do: []
  defp maybe_text(type, text, raw), do: [Helpers.event(:grok, type, session_id(raw), %{"text" => text}, raw)]
  defp session_id(raw) when is_map(raw), do: raw["sessionId"] || raw["session_id"]
  defp session_id(_raw), do: nil
  defp event_type(raw) when is_map(raw), do: raw["type"] || "unknown"
  defp event_type(_raw), do: "unknown"
end
