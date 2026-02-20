defmodule Jido.Harness.Exec.Result do
  @moduledoc false

  @spec extract_result_text([map()], String.t() | nil) :: String.t() | nil
  def extract_result_text(events, raw_output \\ nil) when is_list(events) do
    result_text =
      Enum.find_value(Enum.reverse(events), fn
        %{"type" => "result", "result" => result} when is_binary(result) ->
          String.trim(result)

        %{"type" => "assistant", "message" => %{"content" => content}} when is_list(content) ->
          content
          |> Enum.flat_map(fn
            %{"type" => "text", "text" => text} when is_binary(text) -> [text]
            _ -> []
          end)
          |> Enum.join("")
          |> String.trim()
          |> blank_to_nil()

        %{"output_text" => text} when is_binary(text) ->
          text |> String.trim() |> blank_to_nil()

        _ ->
          nil
      end)

    result_text || raw_output_fallback(raw_output)
  end

  @spec stream_success?(atom(), [map()], list(map())) :: boolean()
  def stream_success?(provider, events, markers) when is_atom(provider) and is_list(events) and is_list(markers) do
    if markers == [] do
      fallback_success?(provider, events)
    else
      Enum.any?(markers, &marker_match?(events, &1))
    end
  end

  defp marker_match?(events, marker) when is_map(marker) do
    expected_type = map_get(marker, :type)
    expected_subtype = map_get(marker, :subtype)
    require_not_error = map_get(marker, :is_error_false, false)

    Enum.any?(events, fn event ->
      event_type = map_get(event, :type)
      event_subtype = map_get(event, :subtype)
      event_is_error = map_get(event, :is_error)

      type_ok = if is_binary(expected_type), do: event_type == expected_type, else: true
      subtype_ok = if is_binary(expected_subtype), do: event_subtype == expected_subtype, else: true
      error_ok = if require_not_error == true, do: event_is_error in [false, nil], else: true
      type_ok and subtype_ok and error_ok
    end)
  end

  defp marker_match?(_events, _marker), do: false

  defp fallback_success?(:codex, events) do
    Enum.any?(events, fn event -> map_get(event, :type) == "turn.completed" end)
  end

  defp fallback_success?(_provider, events) do
    Enum.any?(events, fn event ->
      map_get(event, :type) == "result" and map_get(event, :subtype) in ["success", nil]
    end)
  end

  defp raw_output_fallback(value) when is_binary(value) do
    value
    |> String.trim()
    |> blank_to_nil()
  end

  defp raw_output_fallback(_), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    map_get(map, key, nil)
  end

  defp map_get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
