defmodule Jido.Harness.Adapters.SDKMapper.Gemini do
  @moduledoc false

  alias Jido.Harness.Adapters.Helpers
  alias GeminiCliSdk.Types.{ErrorEvent, InitEvent, MessageEvent, ResultEvent, ToolResultEvent, ToolUseEvent}

  @doc false
  @spec map(term(), String.t() | nil) :: [Jido.Harness.Event.t()]
  def map(%InitEvent{} = event, _sid),
    do: [Helpers.event(:gemini, :run_started, event.session_id, %{"model" => event.model}, event)]

  def map(%MessageEvent{role: "assistant"} = event, sid) do
    type = if event.delta == true, do: :output_text_delta, else: :output_text_final
    [Helpers.event(:gemini, type, sid, %{"text" => event.content}, event)]
  end

  def map(%MessageEvent{} = event, sid),
    do: [Helpers.event(:gemini, :provider_event, sid, %{"role" => event.role, "text" => event.content}, event)]

  def map(%ToolUseEvent{} = event, sid),
    do: [
      Helpers.event(
        :gemini,
        :tool_call,
        sid,
        %{"name" => event.tool_name, "input" => event.parameters, "call_id" => event.tool_id},
        event
      )
    ]

  def map(%ToolResultEvent{} = event, sid),
    do: [
      Helpers.event(
        :gemini,
        :tool_result,
        sid,
        %{"output" => event.output, "call_id" => event.tool_id, "is_error" => event.status != "success"},
        event
      )
    ]

  def map(%ResultEvent{} = event, sid) do
    usage = usage_event(sid, event.stats, event)

    terminal =
      if event.status == "success",
        do: Helpers.event(:gemini, :run_completed, sid, %{"status" => event.status}, event),
        else: Helpers.event(:gemini, :run_failed, sid, %{"status" => event.status, "error" => event.error}, event)

    usage ++ [terminal]
  end

  def map(%ErrorEvent{} = event, sid) do
    type = if event.severity == "fatal", do: :run_failed, else: :provider_event

    [
      Helpers.event(
        :gemini,
        type,
        sid,
        %{"severity" => event.severity, "message" => event.message, "kind" => event.kind},
        event
      )
    ]
  end

  def map(other, sid),
    do: [Helpers.event(:gemini, :provider_event, sid, %{"event_module" => struct_name(other)}, other)]

  defp usage_event(_sid, nil, _raw), do: []

  defp usage_event(sid, usage, raw) do
    payload = Helpers.stringify_keys(if is_struct(usage), do: Map.from_struct(usage), else: usage)
    input = payload["input_tokens"] || 0
    output = payload["output_tokens"] || 0
    payload = Map.put_new(payload, "total_tokens", input + output)
    [Helpers.event(:gemini, :usage, sid, payload, raw)]
  end

  defp struct_name(%{__struct__: module}), do: inspect(module)
  defp struct_name(_value), do: "unknown"
end
