defmodule Jido.Harness.Adapters.SDKMapper do
  @moduledoc false

  alias Jido.Harness.Adapters.Helpers

  alias AmpSdk.Types.{
    AssistantMessage,
    ErrorResultMessage,
    ResultMessage,
    SystemMessage,
    TextContent,
    ThinkingContent,
    ToolResultContent,
    ToolUseContent,
    UserMessage
  }

  alias GeminiCliSdk.Types.{ErrorEvent, InitEvent, MessageEvent, ResultEvent, ToolResultEvent, ToolUseEvent}

  def amp(%SystemMessage{} = message) do
    [
      Helpers.event(
        :amp,
        :run_started,
        message.session_id,
        %{"cwd" => message.cwd, "tools" => message.tools},
        message
      )
    ]
  end

  def amp(%AssistantMessage{} = message) do
    content = if message.message, do: message.message.content || [], else: []

    Enum.flat_map(content, fn
      %TextContent{text: text} ->
        [Helpers.event(:amp, :output_text_delta, message.session_id, %{"text" => text}, message)]

      %ThinkingContent{thinking: text} ->
        [Helpers.event(:amp, :thinking_delta, message.session_id, %{"text" => text}, message)]

      %ToolUseContent{} = tool ->
        [
          Helpers.event(
            :amp,
            :tool_call,
            message.session_id,
            %{"name" => tool.name, "input" => tool.input || %{}, "call_id" => tool.id},
            message
          )
        ]

      _ ->
        []
    end)
  end

  def amp(%UserMessage{} = message) do
    content = if message.message, do: message.message.content || [], else: []

    Enum.flat_map(content, fn
      %ToolResultContent{} = result ->
        [
          Helpers.event(
            :amp,
            :tool_result,
            message.session_id,
            %{"output" => result.content, "call_id" => result.tool_use_id, "is_error" => result.is_error},
            message
          )
        ]

      _ ->
        []
    end)
  end

  def amp(%ResultMessage{} = message) do
    usage = usage_event(:amp, message.session_id, message.usage, message)

    usage ++
      [
        Helpers.event(:amp, :output_text_final, message.session_id, %{"text" => message.result}, message),
        Helpers.event(
          :amp,
          :run_completed,
          message.session_id,
          %{"num_turns" => message.num_turns, "duration_ms" => message.duration_ms},
          message
        )
      ]
  end

  def amp(%ErrorResultMessage{} = message) do
    usage_event(:amp, message.session_id, message.usage, message) ++
      [
        Helpers.event(
          :amp,
          :run_failed,
          message.session_id,
          %{"error" => message.error, "kind" => message.kind},
          message
        )
      ]
  end

  def amp(other),
    do: [Helpers.event(:amp, :provider_event, session_id(other), %{"event_module" => struct_name(other)}, other)]

  def claude(%ClaudeAgentSDK.Message{type: :system, subtype: :init, data: data} = message) do
    [
      Helpers.event(
        :claude,
        :run_started,
        get(data, :session_id),
        %{"cwd" => get(data, :cwd), "model" => get(data, :model), "tools" => get(data, :tools, [])},
        message
      )
    ]
  end

  def claude(%ClaudeAgentSDK.Message{type: :assistant, data: data} = message) do
    sid = get(data, :session_id)

    message
    |> ClaudeAgentSDK.Message.content_blocks()
    |> Enum.flat_map(fn block -> claude_block(block, sid, message) end)
  end

  def claude(%ClaudeAgentSDK.Message{type: :user, data: data} = message) do
    sid = get(data, :session_id)
    message |> ClaudeAgentSDK.Message.content_blocks() |> Enum.flat_map(&claude_block(&1, sid, message))
  end

  def claude(%ClaudeAgentSDK.Message{type: :result, subtype: :success, data: data} = message) do
    sid = get(data, :session_id)

    usage_event(:claude, sid, get(data, :usage), message) ++
      [
        Helpers.event(:claude, :output_text_final, sid, %{"text" => get(data, :result, "")}, message),
        Helpers.event(
          :claude,
          :run_completed,
          sid,
          %{
            "num_turns" => get(data, :num_turns),
            "duration_ms" => get(data, :duration_ms),
            "cost_usd" => get(data, :total_cost_usd)
          },
          message
        )
      ]
  end

  def claude(%ClaudeAgentSDK.Message{type: :result, data: data} = message) do
    [
      Helpers.event(
        :claude,
        :run_failed,
        get(data, :session_id),
        %{"error" => get(data, :error, get(data, :result, "Claude failed"))},
        message
      )
    ]
  end

  def claude(%ClaudeAgentSDK.Message{type: :stream_event, data: data} = message) do
    event = get(data, :event, %{})
    sid = get(data, :session_id)

    case get(event, :type) do
      type when type in ["message_stop", :message_stop] ->
        [Helpers.event(:claude, :turn_completed, sid, %{}, message)]

      _ ->
        case event |> get(:delta, %{}) |> get(:text) do
          text when is_binary(text) and text != "" ->
            [Helpers.event(:claude, :output_text_delta, sid, %{"text" => text}, message)]

          _ ->
            []
        end
    end
  end

  def claude(other),
    do: [Helpers.event(:claude, :provider_event, session_id(other), %{"event_module" => struct_name(other)}, other)]

  def gemini(%InitEvent{} = event, _sid),
    do: [Helpers.event(:gemini, :run_started, event.session_id, %{"model" => event.model}, event)]

  def gemini(%MessageEvent{role: "assistant"} = event, sid) do
    type = if event.delta == true, do: :output_text_delta, else: :output_text_final
    [Helpers.event(:gemini, type, sid, %{"text" => event.content}, event)]
  end

  def gemini(%MessageEvent{} = event, sid),
    do: [Helpers.event(:gemini, :provider_event, sid, %{"role" => event.role, "text" => event.content}, event)]

  def gemini(%ToolUseEvent{} = event, sid),
    do: [
      Helpers.event(
        :gemini,
        :tool_call,
        sid,
        %{"name" => event.tool_name, "input" => event.parameters, "call_id" => event.tool_id},
        event
      )
    ]

  def gemini(%ToolResultEvent{} = event, sid),
    do: [
      Helpers.event(
        :gemini,
        :tool_result,
        sid,
        %{"output" => event.output, "call_id" => event.tool_id, "is_error" => event.status != "success"},
        event
      )
    ]

  def gemini(%ResultEvent{} = event, sid) do
    usage = usage_event(:gemini, sid, event.stats, event)

    terminal =
      if event.status == "success",
        do: Helpers.event(:gemini, :run_completed, sid, %{"status" => event.status}, event),
        else: Helpers.event(:gemini, :run_failed, sid, %{"status" => event.status, "error" => event.error}, event)

    usage ++ [terminal]
  end

  def gemini(%ErrorEvent{} = event, sid) do
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

  def gemini(other, sid),
    do: [Helpers.event(:gemini, :provider_event, sid, %{"event_module" => struct_name(other)}, other)]

  def codex(event) do
    module = struct_name(event)
    sid = session_id(event)

    cond do
      String.ends_with?(module, ".RunItem") ->
        codex(Map.get(event, :event))

      String.ends_with?(module, ".RawResponses") ->
        Enum.flat_map(Map.get(event, :events, []), &codex/1)

      suffix?(module, ["ThreadStarted", "SessionConfigured"]) ->
        [Helpers.event(:codex, :run_started, sid, %{"cwd" => get(event, :cwd)}, event)]

      String.ends_with?(module, "TurnStarted") ->
        [Helpers.event(:codex, :turn_started, sid, %{"turn_id" => get(event, :turn_id)}, event)]

      suffix?(module, ["ItemAgentMessageDelta"]) ->
        maybe_text(:codex, :output_text_delta, sid, item_text(get(event, :item)), event)

      String.ends_with?(module, "CommandOutputDelta") ->
        maybe_text(:codex, :command_output_delta, sid, get(event, :delta), event)

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
        maybe_text(:codex, :thinking_delta, sid, get(event, :delta), event)

      String.ends_with?(module, "ItemCompleted") ->
        codex_item(get(event, :item), sid, event)

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
        usage_event(:codex, sid, get(event, :usage), event)

      String.ends_with?(module, "TurnCompleted") ->
        usage_event(:codex, sid, get(event, :usage), event) ++
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

  defp codex_item(nil, sid, raw),
    do: [Helpers.event(:codex, :provider_event, sid, %{"event_module" => struct_name(raw)}, raw)]

  defp codex_item(item, sid, raw) do
    module = struct_name(item)

    cond do
      String.ends_with?(module, "AgentMessage") ->
        maybe_text(:codex, :output_text_final, sid, get(item, :text), raw)

      String.ends_with?(module, "Reasoning") ->
        maybe_text(:codex, :thinking_delta, sid, get(item, :text), raw)

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

  defp claude_block(%{type: :text, text: text}, sid, raw),
    do: [Helpers.event(:claude, :output_text_delta, sid, %{"text" => text}, raw)]

  defp claude_block(%{type: :thinking, thinking: text}, sid, raw),
    do: [Helpers.event(:claude, :thinking_delta, sid, %{"text" => text}, raw)]

  defp claude_block(%{type: :tool_use} = block, sid, raw),
    do: [
      Helpers.event(
        :claude,
        :tool_call,
        sid,
        %{"name" => get(block, :name), "input" => get(block, :input, %{}), "call_id" => get(block, :id)},
        raw
      )
    ]

  defp claude_block(%{type: :tool_result} = block, sid, raw),
    do: [
      Helpers.event(
        :claude,
        :tool_result,
        sid,
        %{
          "output" => get(block, :content),
          "call_id" => get(block, :tool_use_id),
          "is_error" => get(block, :is_error, false)
        },
        raw
      )
    ]

  defp claude_block(_block, _sid, _raw), do: []

  defp usage_event(_provider, _sid, nil, _raw), do: []

  defp usage_event(provider, sid, usage, raw) do
    payload = Helpers.stringify_keys(if is_struct(usage), do: Map.from_struct(usage), else: usage)
    input = payload["input_tokens"] || 0
    output = payload["output_tokens"] || 0
    payload = Map.put_new(payload, "total_tokens", input + output)
    [Helpers.event(provider, :usage, sid, payload, raw)]
  end

  defp maybe_text(_provider, _type, _sid, text, _raw) when not is_binary(text) or text == "", do: []
  defp maybe_text(provider, type, sid, text, raw), do: [Helpers.event(provider, type, sid, %{"text" => text}, raw)]
  defp item_text(item), do: get(item, :delta, get(item, :text))
  defp session_id(value), do: get(value, :thread_id, get(value, :session_id))
  defp struct_name(%{__struct__: module}), do: inspect(module)
  defp struct_name(_value), do: "unknown"
  defp suffix?(module, suffixes), do: Enum.any?(suffixes, &String.ends_with?(module, &1))
  defp get(map, key, default \\ nil)
  defp get(map, key, default) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp get(_value, _key, default), do: default
end
