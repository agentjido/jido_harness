defmodule Jido.Harness.Adapters.SDKMapper.Amp do
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

  @doc false
  @spec map(term()) :: [Jido.Harness.Event.t()]
  def map(%SystemMessage{} = message) do
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

  def map(%AssistantMessage{} = message) do
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

  def map(%UserMessage{} = message) do
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

  def map(%ResultMessage{} = message) do
    usage = usage_event(message.session_id, message.usage, message)

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

  def map(%ErrorResultMessage{} = message) do
    usage_event(message.session_id, message.usage, message) ++
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

  def map(other),
    do: [Helpers.event(:amp, :provider_event, session_id(other), %{"event_module" => struct_name(other)}, other)]

  defp usage_event(_sid, nil, _raw), do: []

  defp usage_event(sid, usage, raw) do
    payload = Helpers.stringify_keys(if is_struct(usage), do: Map.from_struct(usage), else: usage)
    input = payload["input_tokens"] || 0
    output = payload["output_tokens"] || 0
    payload = Map.put_new(payload, "total_tokens", input + output)
    [Helpers.event(:amp, :usage, sid, payload, raw)]
  end

  defp session_id(value), do: get(value, :thread_id, get(value, :session_id))
  defp struct_name(%{__struct__: module}), do: inspect(module)
  defp struct_name(_value), do: "unknown"
  defp get(map, key, default \\ nil)
  defp get(map, key, default) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp get(_value, _key, default), do: default
end
