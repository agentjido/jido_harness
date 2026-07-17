defmodule Jido.Harness.Adapters.SDKMapper.Codex do
  @moduledoc false

  alias Jido.Harness.Adapters.Helpers

  @doc false
  @spec map(term()) :: [Jido.Harness.Event.t()]
  def map(event) do
    module = struct_name(event)
    sid = session_id(event)

    cond do
      String.ends_with?(module, ".RunItem") ->
        map(Map.get(event, :event))

      String.ends_with?(module, ".RawResponses") ->
        Enum.flat_map(Map.get(event, :events, []), &map/1)

      suffix?(module, ["ThreadStarted", "SessionConfigured"]) ->
        [Helpers.event(:codex, :run_started, sid, %{"cwd" => get(event, :cwd)}, event)]

      String.ends_with?(module, "TurnStarted") ->
        [Helpers.event(:codex, :turn_started, sid, %{"turn_id" => get(event, :turn_id)}, event)]

      suffix?(module, ["ItemAgentMessageDelta"]) ->
        maybe_text(:output_text_delta, sid, item_text(get(event, :item)), event)

      String.ends_with?(module, "CommandOutputDelta") ->
        maybe_text(:command_output_delta, sid, get(event, :delta), event)

      String.ends_with?(module, "FileChangeOutputDelta") ->
        [
          Helpers.event(
            :codex,
            :file_change,
            sid,
            %{"item_id" => get(event, :item_id), "delta" => get(event, :delta)},
            event
          )
        ]

      String.ends_with?(module, "TurnDiffUpdated") ->
        [Helpers.event(:codex, :file_change, sid, %{"diff" => get(event, :diff)}, event)]

      String.ends_with?(module, "TurnPlanUpdated") ->
        [
          Helpers.event(
            :codex,
            :plan_updated,
            sid,
            %{"explanation" => get(event, :explanation), "plan" => get(event, :plan, [])},
            event
          )
        ]

      suffix?(module, ["ReasoningDelta", "ReasoningSummaryDelta"]) ->
        maybe_text(:thinking_delta, sid, get(event, :delta), event)

      String.ends_with?(module, "ItemCompleted") ->
        map_item(get(event, :item), sid, event)

      String.ends_with?(module, "ToolCallRequested") ->
        [
          Helpers.event(
            :codex,
            :tool_call,
            sid,
            %{"name" => get(event, :tool_name), "input" => get(event, :arguments), "call_id" => get(event, :call_id)},
            event
          )
        ]

      String.ends_with?(module, "ToolCallCompleted") ->
        [
          Helpers.event(
            :codex,
            :tool_result,
            sid,
            %{
              "name" => get(event, :tool_name),
              "output" => get(event, :output),
              "call_id" => get(event, :call_id),
              "is_error" => false
            },
            event
          )
        ]

      String.ends_with?(module, "ThreadTokenUsageUpdated") ->
        usage_event(sid, get(event, :usage), event)

      String.ends_with?(module, "TurnCompleted") ->
        usage_event(sid, get(event, :usage), event) ++
          [
            Helpers.event(:codex, :turn_completed, sid, %{"status" => get(event, :status)}, event),
            Helpers.event(:codex, :run_completed, sid, %{"status" => get(event, :status)}, event)
          ]

      suffix?(module, ["TurnFailed", ".Error"]) ->
        [
          Helpers.event(
            :codex,
            :run_failed,
            sid,
            %{"error" => get(event, :error, get(event, :message, "Codex failed"))},
            event
          )
        ]

      String.ends_with?(module, "TurnAborted") ->
        [Helpers.event(:codex, :run_cancelled, sid, %{"reason" => get(event, :reason)}, event)]

      true ->
        [Helpers.event(:codex, :provider_event, sid, %{"event_module" => module}, event)]
    end
  end

  defp map_item(nil, sid, raw),
    do: [Helpers.event(:codex, :provider_event, sid, %{"event_module" => struct_name(raw)}, raw)]

  defp map_item(item, sid, raw) do
    module = struct_name(item)

    cond do
      String.ends_with?(module, "AgentMessage") ->
        maybe_text(:output_text_final, sid, get(item, :text), raw)

      String.ends_with?(module, "Reasoning") ->
        maybe_text(:thinking_delta, sid, get(item, :text), raw)

      String.ends_with?(module, "CommandExecution") ->
        call_id = get(item, :id, "exec-#{System.unique_integer([:positive])}")

        [
          Helpers.event(
            :codex,
            :tool_call,
            sid,
            %{
              "name" => "exec_command",
              "input" => %{"cmd" => get(item, :command), "cwd" => get(item, :cwd)},
              "call_id" => call_id
            },
            raw
          ),
          Helpers.event(
            :codex,
            :tool_result,
            sid,
            %{
              "name" => "exec_command",
              "output" => get(item, :aggregated_output, ""),
              "call_id" => call_id,
              "is_error" => get(item, :exit_code) not in [nil, 0]
            },
            raw
          )
        ]

      String.ends_with?(module, "McpToolCall") ->
        call_id = get(item, :id, "mcp-#{System.unique_integer([:positive])}")

        [
          Helpers.event(
            :codex,
            :tool_call,
            sid,
            %{"name" => get(item, :tool, "mcp_tool"), "input" => get(item, :arguments, %{}), "call_id" => call_id},
            raw
          ),
          Helpers.event(
            :codex,
            :tool_result,
            sid,
            %{
              "output" => get(item, :result, get(item, :error, "")),
              "call_id" => call_id,
              "is_error" => not is_nil(get(item, :error))
            },
            raw
          )
        ]

      String.ends_with?(module, "FileChange") ->
        [
          Helpers.event(
            :codex,
            :file_change,
            sid,
            %{"changes" => get(item, :changes), "status" => get(item, :status)},
            raw
          )
        ]

      true ->
        [Helpers.event(:codex, :provider_event, sid, %{"item_module" => module}, raw)]
    end
  end

  defp usage_event(_sid, nil, _raw), do: []

  defp usage_event(sid, usage, raw) do
    payload = Helpers.stringify_keys(if is_struct(usage), do: Map.from_struct(usage), else: usage)
    input = payload["input_tokens"] || 0
    output = payload["output_tokens"] || 0
    payload = Map.put_new(payload, "total_tokens", input + output)
    [Helpers.event(:codex, :usage, sid, payload, raw)]
  end

  defp maybe_text(_type, _sid, text, _raw) when not is_binary(text) or text == "", do: []
  defp maybe_text(type, sid, text, raw), do: [Helpers.event(:codex, type, sid, %{"text" => text}, raw)]
  defp item_text(item), do: get(item, :delta, get(item, :text))
  defp session_id(value), do: get(value, :thread_id, get(value, :session_id))
  defp struct_name(%{__struct__: module}), do: inspect(module)
  defp struct_name(_value), do: "unknown"
  defp suffix?(module, suffixes), do: Enum.any?(suffixes, &String.ends_with?(module, &1))
  defp get(map, key, default \\ nil)
  defp get(map, key, default) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp get(_value, _key, default), do: default
end
