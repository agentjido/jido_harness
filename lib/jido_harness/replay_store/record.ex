defmodule Jido.Harness.ReplayStore.Record do
  @moduledoc false

  alias Jido.Harness.Redaction

  @doc "Prepares one JSON-compatible Signal record for every store and fallback."
  @spec prepare(Jido.Signal.t(), Redaction.prepared() | [String.t()]) :: map()
  def prepare(%Jido.Signal{} = signal, secrets) do
    secrets = if is_list(secrets), do: Redaction.prepare(secrets), else: secrets

    wire =
      signal
      |> Jido.Signal.to_map()
      |> sanitize(secrets)
      |> redact_wire(secrets)

    %{
      "format_version" => 2,
      "sequence" => Jido.Harness.Signal.sequence(signal),
      "signal" => wire
    }
  end

  @doc "Measures the logical record budget as JSON bytes, without a line separator."
  @spec bytes(map()) :: non_neg_integer()
  def bytes(record), do: record |> Jason.encode_to_iodata!() |> IO.iodata_length()

  @envelope_keys ~w(specversion id source type subject time datacontenttype dataschema data data_base64)

  defp redact_wire(wire, secrets) do
    Map.new(wire, fn
      {"data", value} -> {"data", Redaction.redact(value, secrets)}
      {key, value} when key in @envelope_keys -> {key, value}
      {key, value} -> {key, Redaction.redact(value, secrets)}
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
