defmodule Jido.Harness.Adapters.JSONMapper do
  @moduledoc false

  alias Jido.Harness.Adapters.Helpers

  def map(provider, raw) when is_map(raw) do
    type = value(raw, [:type, :event_type, :kind], "") |> to_string() |> String.downcase()
    session_id = value(raw, [:session_id, :sessionId, :thread_id, :threadId])
    text = text(raw)

    cond do
      type in ["init", "session_started", "session.start", "session.started"] ->
        Helpers.event(provider, :session_started, session_id, raw, raw)

      type in ["turn_started", "turn.start", "turn.started"] ->
        Helpers.event(provider, :turn_started, session_id, raw, raw)

      type in ["tool_call", "tool_use", "tool.started"] ->
        Helpers.event(
          provider,
          :tool_call,
          session_id,
          %{
            "name" => value(raw, [:name, :tool_name, :tool]),
            "input" => value(raw, [:input, :parameters, :arguments], %{}),
            "call_id" => value(raw, [:call_id, :tool_id, :id])
          },
          raw
        )

      type in ["tool_result", "tool.completed"] ->
        Helpers.event(
          provider,
          :tool_result,
          session_id,
          %{
            "output" => value(raw, [:output, :result, :content]),
            "call_id" => value(raw, [:call_id, :tool_id, :id]),
            "is_error" => value(raw, [:is_error], value(raw, [:status]) in ["error", "failed"])
          },
          raw
        )

      type in ["usage", "token_usage"] ->
        Helpers.event(provider, :usage, session_id, value(raw, [:usage, :stats], raw), raw)

      failure?(type, raw) ->
        Helpers.event(
          provider,
          :session_failed,
          session_id,
          %{"error" => value(raw, [:error, :message], inspect(raw))},
          raw
        )

      cancelled?(type, raw) ->
        Helpers.event(provider, :session_cancelled, session_id, %{"reason" => value(raw, [:reason], "cancelled")}, raw)

      completed?(type, raw) ->
        events =
          if is_binary(text) and text != "",
            do: [Helpers.event(provider, :output_text_final, session_id, %{"text" => text}, raw)],
            else: []

        events ++
          [
            Helpers.event(
              provider,
              :session_completed,
              session_id,
              %{"status" => value(raw, [:status], "success")},
              raw
            )
          ]

      is_binary(text) and text != "" ->
        event_type =
          if type in ["final", "text.final", "output_text_final"], do: :output_text_final, else: :output_text_delta

        Helpers.event(provider, event_type, session_id, %{"text" => text}, raw)

      true ->
        Helpers.event(provider, :provider_event, session_id, %{"type" => type, "mapped" => false}, raw)
    end
  end

  def map(provider, raw),
    do: Helpers.event(provider, :provider_event, nil, %{"mapped" => false, "value_type" => value_type(raw)}, raw)

  defp completed?(type, raw) do
    (type in ["result", "complete", "completed", "session_completed", "session.complete", "session.completed"] and
       not failure?(type, raw)) or value(raw, [:status]) == "success"
  end

  defp failure?(type, raw),
    do:
      type in ["error", "failed", "session_failed", "session.failed"] or value(raw, [:status]) in ["error", "failed"] or
        value(raw, [:is_error]) == true

  defp cancelled?(type, _raw), do: type in ["cancelled", "canceled", "session_cancelled", "session.cancelled"]

  defp text(raw) do
    value(raw, [:text, :delta, :output_text, :content, :result, :message])
    |> case do
      text when is_binary(text) -> String.trim(text)
      %{} = message -> value(message, [:text, :content])
      _ -> nil
    end
  end

  defp value(map, keys, default \\ nil)

  defp value(map, [key | rest], default) do
    case fetch(map, key) do
      nil -> value(map, rest, default)
      found -> found
    end
  end

  defp value(_map, [], default), do: default

  defp fetch(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp fetch(_map, _key), do: nil

  defp value_type(value) when is_atom(value), do: "atom"
  defp value_type(value) when is_binary(value), do: "string"
  defp value_type(value) when is_list(value), do: "list"
  defp value_type(value) when is_number(value), do: "number"
  defp value_type(_value), do: "other"
end
