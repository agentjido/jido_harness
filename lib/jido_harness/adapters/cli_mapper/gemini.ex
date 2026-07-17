defmodule Jido.Harness.Adapters.CLIMapper.Gemini do
  @moduledoc "Maps Gemini stream-json records while retaining CLI session state."

  alias Jido.Harness.Adapters.Helpers
  alias Jido.Harness.Event

  @doc "Maps one Gemini JSONL record and returns the updated session identifier."
  @spec map(term(), String.t() | nil) :: {[Event.t()], String.t() | nil}
  def map(%{"type" => "init"} = raw, _session_id) do
    sid = raw["session_id"]
    {[Helpers.event(:gemini, :run_started, sid, %{"model" => raw["model"]}, raw)], sid}
  end

  def map(%{"type" => "message", "role" => "assistant"} = raw, session_id) do
    type = if raw["delta"] == true, do: :output_text_delta, else: :output_text_final
    {[Helpers.event(:gemini, type, session_id, %{"text" => raw["content"] || ""}, raw)], session_id}
  end

  def map(%{"type" => "message"} = raw, session_id) do
    {[Helpers.event(:gemini, :provider_event, session_id, %{"role" => raw["role"], "text" => raw["content"]}, raw)],
     session_id}
  end

  def map(%{"type" => "tool_use"} = raw, session_id) do
    {[
       Helpers.event(
         :gemini,
         :tool_call,
         session_id,
         %{"name" => raw["tool_name"], "input" => raw["parameters"] || %{}, "call_id" => raw["tool_id"]},
         raw
       )
     ], session_id}
  end

  def map(%{"type" => "tool_result"} = raw, session_id) do
    {[
       Helpers.event(
         :gemini,
         :tool_result,
         session_id,
         %{"output" => raw["output"], "call_id" => raw["tool_id"], "is_error" => raw["status"] != "success"},
         raw
       )
     ], session_id}
  end

  def map(%{"type" => "result"} = raw, session_id) do
    usage = usage_event(session_id, raw["stats"], raw)

    terminal =
      if raw["status"] == "success" do
        Helpers.event(:gemini, :run_completed, session_id, %{"status" => raw["status"]}, raw)
      else
        Helpers.event(
          :gemini,
          :run_failed,
          session_id,
          %{"status" => raw["status"], "error" => error_message(raw["error"])},
          raw
        )
      end

    {usage ++ [terminal], session_id}
  end

  def map(%{"type" => "error"} = raw, session_id) do
    type = if raw["severity"] == "fatal", do: :run_failed, else: :provider_event

    {[
       Helpers.event(
         :gemini,
         type,
         session_id,
         %{"severity" => raw["severity"], "message" => raw["message"], "kind" => raw["kind"]},
         raw
       )
     ], session_id}
  end

  def map(raw, session_id) do
    {[Helpers.event(:gemini, :provider_event, session_id, %{"type" => event_type(raw), "mapped" => false}, raw)],
     session_id}
  end

  defp usage_event(_session_id, nil, _raw), do: []

  defp usage_event(session_id, usage, raw) when is_map(usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0
    [Helpers.event(:gemini, :usage, session_id, Map.put_new(usage, "total_tokens", input + output), raw)]
  end

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(message) when is_binary(message), do: message
  defp error_message(error), do: inspect(error)
  defp event_type(raw) when is_map(raw), do: raw["type"] || "unknown"
  defp event_type(_raw), do: "unknown"
end
