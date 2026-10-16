defmodule Jido.Harness.ReplayStore.Record do
  @moduledoc false

  alias Jido.Harness.Redaction

  @doc "Prepares one JSON-compatible record for every store and fallback."
  @spec prepare(map(), Redaction.prepared() | [String.t()]) :: map()
  def prepare(event, secrets) do
    event
    |> plain_map()
    |> Map.drop([:raw, "raw", :format_version, "format_version"])
    |> Map.put("raw", nil)
    |> Map.put("format_version", 1)
    |> Redaction.redact(secrets)
    |> sanitize()
  end

  @doc "Measures the logical record budget as JSON bytes, without a line separator."
  @spec bytes(map()) :: non_neg_integer()
  def bytes(record), do: record |> Jason.encode_to_iodata!() |> IO.iodata_length()

  defp plain_map(%_{} = value), do: Map.from_struct(value)
  defp plain_map(value), do: value

  defp sanitize(%_{} = value), do: value |> Map.from_struct() |> sanitize()
  defp sanitize(value) when is_map(value), do: Map.new(value, fn {k, v} -> {to_string(k), sanitize(v)} end)
  defp sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)

  defp sanitize(value) when is_binary(value),
    do: if(String.valid?(value), do: value, else: %{"encoding" => "base64", "data" => Base.encode64(value)})

  defp sanitize(value) when is_boolean(value) or is_nil(value) or is_number(value), do: value
  defp sanitize(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize(value), do: inspect(value, limit: 50, printable_limit: 2_000)
end
