defmodule Jido.Harness.Adapters.CLIMapper.Grok do
  @moduledoc false

  alias Jido.Harness.Adapters.Helpers
  alias Jido.Harness.Event

  @doc "Maps one Grok streaming-json record to zero or more harness events."
  @spec map(term()) :: [Event.t()]
  def map(%{"type" => "thought", "data" => text} = raw) when is_binary(text) do
    maybe_text(:thinking_delta, text, raw)
  end

  def map(%{"type" => "text", "data" => text} = raw) when is_binary(text) do
    maybe_text(:output_text_delta, text, raw)
  end

  def map(%{"type" => "usage", "usage" => usage} = raw) when is_map(usage) do
    [Helpers.event(:grok, :usage, session_id(raw), normalize_usage(usage), raw)]
  end

  def map(%{"type" => "tool_call"} = raw) do
    [
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
    ]
  end

  def map(%{"type" => "tool_call_update", "status" => status} = raw)
      when status in ["completed", "failed", "error"] do
    [
      Helpers.event(
        :grok,
        :tool_result,
        session_id(raw),
        %{
          "output" => raw["rawOutput"] || raw["content"],
          "call_id" => raw["toolCallId"],
          "is_error" => status in ["failed", "error"]
        },
        raw
      )
    ]
  end

  def map(%{"type" => "error"} = raw) do
    [
      Helpers.event(
        :grok,
        :run_failed,
        session_id(raw),
        %{"error" => raw["message"] || raw["error"] || raw["data"] || "Grok failed"},
        raw
      )
    ]
  end

  def map(%{"type" => "end", "stopReason" => stop_reason} = raw)
      when stop_reason in ["cancelled", "canceled"] do
    usage_event(raw) ++
      [
        Helpers.event(
          :grok,
          :run_cancelled,
          session_id(raw),
          end_payload(raw),
          raw
        )
      ]
  end

  def map(%{"type" => "end", "stopReason" => stop_reason} = raw)
      when stop_reason in ["error", "failed"] do
    usage_event(raw) ++
      [
        Helpers.event(
          :grok,
          :run_failed,
          session_id(raw),
          Map.put(end_payload(raw), "error", raw["message"] || "Grok failed"),
          raw
        )
      ]
  end

  def map(%{"type" => "end"} = raw) do
    usage_event(raw) ++
      [
        Helpers.event(
          :grok,
          :run_completed,
          session_id(raw),
          end_payload(raw),
          raw
        )
      ]
  end

  def map(raw) do
    [
      Helpers.event(
        :grok,
        :provider_event,
        session_id(raw),
        %{"type" => event_type(raw), "mapped" => false},
        raw
      )
    ]
  end

  defp usage_event(%{"usage" => usage} = raw) when is_map(usage) do
    [Helpers.event(:grok, :usage, session_id(raw), normalize_usage(usage), raw)]
  end

  defp usage_event(_raw), do: []

  defp normalize_usage(usage) do
    Map.put_new_lazy(usage, "total_tokens", fn ->
      Enum.sum([
        usage["input_tokens"] || 0,
        usage["output_tokens"] || 0,
        usage["cache_read_input_tokens"] || 0,
        usage["cache_creation_input_tokens"] || 0
      ])
    end)
  end

  defp end_payload(raw) do
    %{
      "stop_reason" => raw["stopReason"],
      "request_id" => raw["requestId"],
      "num_turns" => raw["num_turns"],
      "cost_usd" => raw["total_cost_usd"]
    }
  end

  defp maybe_text(_type, "", _raw), do: []
  defp maybe_text(type, text, raw), do: [Helpers.event(:grok, type, session_id(raw), %{"text" => text}, raw)]
  defp session_id(raw) when is_map(raw), do: raw["sessionId"] || raw["session_id"]
  defp session_id(_raw), do: nil
  defp event_type(raw) when is_map(raw), do: raw["type"] || "unknown"
  defp event_type(_raw), do: "unknown"
end
