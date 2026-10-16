defmodule Jido.Harness.ReplayStore.Record do
  @moduledoc false

  alias Jido.Harness.Redaction

  @doc "Prepares one JSON-compatible record for every store and fallback."
  @spec prepare(map(), Redaction.prepared() | [String.t()]) :: map()
  def prepare(event, secrets) do
    secrets = if is_list(secrets), do: Redaction.prepare(secrets), else: secrets

    event
    |> plain_map()
    |> Map.drop([:raw, "raw", :format_version, "format_version"])
    |> Map.put("raw", nil)
    |> Map.put("format_version", 1)
    |> Redaction.redact(secrets)
    |> sanitize_envelope(secrets)
  end

  @doc "Measures the logical record budget as JSON bytes, without a line separator."
  @spec bytes(map()) :: non_neg_integer()
  def bytes(record), do: record |> Jason.encode_to_iodata!() |> IO.iodata_length()

  defp plain_map(%_{} = value), do: Map.from_struct(value)
  defp plain_map(value), do: value

  defp sanitize_envelope(value, secrets) do
    Map.new(value, fn {key, value} ->
      value =
        if key in [:type, :provider, :stream, "type", "provider", "stream"] and is_atom(value) and not is_nil(value),
          do: Atom.to_string(value),
          else: sanitize(value, secrets)

      {to_string(key), value}
    end)
  end

  defp sanitize(%_{} = value, secrets), do: value |> Map.from_struct() |> sanitize(secrets)

  defp sanitize(value, secrets) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), sanitize(v, secrets)} end)

  defp sanitize(value, secrets) when is_list(value), do: Enum.map(value, &sanitize(&1, secrets))

  defp sanitize(value, _secrets) when is_binary(value),
    do: if(String.valid?(value), do: value, else: %{"encoding" => "base64", "data" => Base.encode64(value)})

  defp sanitize(value, _secrets) when is_boolean(value) or is_nil(value) or is_number(value), do: value
  defp sanitize(value, secrets) when is_atom(value), do: value |> Atom.to_string() |> Redaction.redact(secrets)
  defp sanitize(value, secrets), do: value |> inspect(limit: 50, printable_limit: 2_000) |> Redaction.redact(secrets)
end
