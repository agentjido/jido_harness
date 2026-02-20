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
    require_not_error = map_get(marker, :is_error_false, false)
    expected_fields = normalize_expected_fields(marker)

    Enum.any?(events, fn event ->
      event_is_error = map_get(event, :is_error)

      fields_ok =
        Enum.all?(expected_fields, fn {field, expected_value} ->
          case map_get_by_normalized_key(event, field, :__missing__) do
            :__missing__ -> false
            actual_value -> actual_value == expected_value
          end
        end)

      error_ok = if require_not_error == true, do: event_is_error in [false, nil], else: true
      fields_ok and error_ok
    end)
  end

  defp marker_match?(_events, _marker), do: false

  defp normalize_expected_fields(marker) when is_map(marker) do
    marker
    |> Enum.reduce([], fn {key, value}, acc ->
      normalized_key = normalize_key(key)

      if normalized_key == "is_error_false" do
        acc
      else
        [{normalized_key, value} | acc]
      end
    end)
    |> Enum.reverse()
  end

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

  defp map_get_by_normalized_key(map, key, default) when is_map(map) and is_binary(key) do
    map
    |> Enum.reduce_while(default, fn {map_key, value}, acc ->
      if normalize_key(map_key) == key do
        {:halt, value}
      else
        {:cont, acc}
      end
    end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: to_string(key)
end
