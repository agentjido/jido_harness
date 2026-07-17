defmodule Jido.Harness.Adapters.SDKMapper.Claude do
  @moduledoc false

  alias Jido.Harness.Adapters.Helpers

  @doc false
  @spec map(term()) :: [Jido.Harness.Event.t()]
  def map(%ClaudeAgentSDK.Message{type: :system, subtype: :init, data: data} = message) do
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

  def map(%ClaudeAgentSDK.Message{type: :assistant, data: data} = message) do
    sid = get(data, :session_id)

    message
    |> ClaudeAgentSDK.Message.content_blocks()
    |> Enum.flat_map(fn block -> content_block(block, sid, message) end)
  end

  def map(%ClaudeAgentSDK.Message{type: :user, data: data} = message) do
    sid = get(data, :session_id)
    message |> ClaudeAgentSDK.Message.content_blocks() |> Enum.flat_map(&content_block(&1, sid, message))
  end

  def map(%ClaudeAgentSDK.Message{type: :result, subtype: :success, data: data} = message) do
    sid = get(data, :session_id)

    usage_event(sid, get(data, :usage), message) ++
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

  def map(%ClaudeAgentSDK.Message{type: :result, data: data} = message) do
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

  def map(%ClaudeAgentSDK.Message{type: :stream_event, data: data} = message) do
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

  def map(other),
    do: [Helpers.event(:claude, :provider_event, session_id(other), %{"event_module" => struct_name(other)}, other)]

  defp content_block(%{type: :text, text: text}, sid, raw),
    do: [Helpers.event(:claude, :output_text_delta, sid, %{"text" => text}, raw)]

  defp content_block(%{type: :thinking, thinking: text}, sid, raw),
    do: [Helpers.event(:claude, :thinking_delta, sid, %{"text" => text}, raw)]

  defp content_block(%{type: :tool_use} = block, sid, raw),
    do: [
      Helpers.event(
        :claude,
        :tool_call,
        sid,
        %{"name" => get(block, :name), "input" => get(block, :input, %{}), "call_id" => get(block, :id)},
        raw
      )
    ]

  defp content_block(%{type: :tool_result} = block, sid, raw),
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

  defp content_block(_block, _sid, _raw), do: []

  defp usage_event(_sid, nil, _raw), do: []

  defp usage_event(sid, usage, raw) do
    payload = Helpers.stringify_keys(if is_struct(usage), do: Map.from_struct(usage), else: usage)
    input = payload["input_tokens"] || 0
    output = payload["output_tokens"] || 0
    payload = Map.put_new(payload, "total_tokens", input + output)
    [Helpers.event(:claude, :usage, sid, payload, raw)]
  end

  defp session_id(value), do: get(value, :thread_id, get(value, :session_id))
  defp struct_name(%{__struct__: module}), do: inspect(module)
  defp struct_name(_value), do: "unknown"
  defp get(map, key, default \\ nil)
  defp get(map, key, default) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp get(_value, _key, default), do: default
end
