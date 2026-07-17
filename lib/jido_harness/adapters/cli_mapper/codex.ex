defmodule Jido.Harness.Adapters.CLIMapper.Codex do
  @moduledoc "Maps Codex exec-json records into provider-neutral harness events."

  alias Jido.Harness.Adapters.Helpers
  alias Jido.Harness.Event

  @doc "Maps one Codex JSONL record to zero or more harness events."
  @spec map(term()) :: [Event.t()]
  def map(%{"type" => "thread.started"} = raw) do
    [Helpers.event(:codex, :run_started, raw["thread_id"], %{}, raw)]
  end

  def map(%{"type" => "turn.started"} = raw) do
    [Helpers.event(:codex, :turn_started, raw["thread_id"], %{"turn_id" => raw["turn_id"]}, raw)]
  end

  def map(%{"type" => "turn.completed"} = raw) do
    sid = raw["thread_id"]
    status = raw["status"]

    terminal =
      if status in ["failed", "error"] or not is_nil(raw["error"]) do
        Helpers.event(:codex, :run_failed, sid, %{"status" => status, "error" => error_message(raw)}, raw)
      else
        Helpers.event(:codex, :run_completed, sid, %{"status" => status}, raw)
      end

    usage_event(sid, raw["usage"], raw) ++
      [Helpers.event(:codex, :turn_completed, sid, %{"status" => status}, raw), terminal]
  end

  def map(%{"type" => type} = raw) when type in ["turn.failed", "error"] do
    [Helpers.event(:codex, :run_failed, raw["thread_id"], %{"error" => error_message(raw)}, raw)]
  end

  def map(%{"type" => "turn.aborted"} = raw) do
    [Helpers.event(:codex, :run_cancelled, raw["thread_id"], %{"reason" => raw["reason"]}, raw)]
  end

  def map(%{"type" => "item.completed", "item" => item} = raw), do: map_item(item, raw)

  def map(%{"type" => "item.agent_message.delta", "item" => item} = raw) do
    maybe_text(:output_text_delta, raw["thread_id"], item["delta"] || item["text"], raw)
  end

  def map(%{"type" => type} = raw) when type in ["thread.tokenUsage.updated", "thread/tokenUsage/updated"] do
    usage_event(raw["thread_id"], raw["usage"] || raw["token_usage"], raw)
  end

  def map(%{"type" => type} = raw) when type in ["turn.diff.updated", "turn/diff/updated"] do
    [Helpers.event(:codex, :file_change, raw["thread_id"], %{"diff" => raw["diff"] || raw["delta"]}, raw)]
  end

  def map(%{"type" => type} = raw) when type in ["turn.plan.updated", "turn/plan/updated"] do
    [
      Helpers.event(
        :codex,
        :plan_updated,
        raw["thread_id"],
        %{"explanation" => raw["explanation"], "plan" => raw["plan"] || []},
        raw
      )
    ]
  end

  def map(raw) do
    [Helpers.event(:codex, :provider_event, session_id(raw), %{"type" => event_type(raw), "mapped" => false}, raw)]
  end

  defp map_item(%{"type" => "agent_message"} = item, raw) do
    maybe_text(:output_text_final, raw["thread_id"], item["text"], raw)
  end

  defp map_item(%{"type" => "reasoning"} = item, raw) do
    maybe_text(:thinking_delta, raw["thread_id"], item["text"], raw)
  end

  defp map_item(%{"type" => "command_execution"} = item, raw) do
    sid = raw["thread_id"]
    call_id = item["id"] || "command"

    [
      Helpers.event(
        :codex,
        :tool_call,
        sid,
        %{"name" => "exec_command", "input" => %{"cmd" => item["command"], "cwd" => item["cwd"]}, "call_id" => call_id},
        raw
      ),
      Helpers.event(
        :codex,
        :tool_result,
        sid,
        %{
          "name" => "exec_command",
          "output" => item["aggregated_output"] || "",
          "call_id" => call_id,
          "is_error" => item["exit_code"] not in [nil, 0] or item["status"] in ["failed", "declined"]
        },
        raw
      )
    ]
  end

  defp map_item(%{"type" => "mcp_tool_call"} = item, raw) do
    sid = raw["thread_id"]
    call_id = item["id"] || "mcp"

    [
      Helpers.event(
        :codex,
        :tool_call,
        sid,
        %{"name" => item["tool"] || "mcp_tool", "input" => item["arguments"] || %{}, "call_id" => call_id},
        raw
      ),
      Helpers.event(
        :codex,
        :tool_result,
        sid,
        %{
          "output" => item["result"] || item["error"] || "",
          "call_id" => call_id,
          "is_error" => not is_nil(item["error"])
        },
        raw
      )
    ]
  end

  defp map_item(%{"type" => "file_change"} = item, raw) do
    [
      Helpers.event(
        :codex,
        :file_change,
        raw["thread_id"],
        %{"changes" => item["changes"], "status" => item["status"]},
        raw
      )
    ]
  end

  defp map_item(item, raw) do
    [Helpers.event(:codex, :provider_event, raw["thread_id"], %{"item_type" => item["type"] || "unknown"}, raw)]
  end

  defp usage_event(_sid, nil, _raw), do: []

  defp usage_event(sid, usage, raw) when is_map(usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0
    [Helpers.event(:codex, :usage, sid, Map.put_new(usage, "total_tokens", input + output), raw)]
  end

  defp maybe_text(_type, _sid, text, _raw) when not is_binary(text) or text == "", do: []
  defp maybe_text(type, sid, text, raw), do: [Helpers.event(:codex, type, sid, %{"text" => text}, raw)]
  defp error_message(raw), do: raw["error"] || raw["message"] || "Codex failed"
  defp session_id(raw) when is_map(raw), do: raw["thread_id"] || raw["session_id"]
  defp session_id(_raw), do: nil
  defp event_type(raw) when is_map(raw), do: raw["type"] || "unknown"
  defp event_type(_raw), do: "unknown"
end
