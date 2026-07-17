defmodule Jido.Harness.Adapters.CLIArgs do
  @moduledoc false

  @doc "Builds a flag/value pair, omitting nil values."
  @spec pair(String.t(), term()) :: [String.t()]
  def pair(_flag, nil), do: []
  def pair(flag, value), do: [flag, to_string(value)]

  @doc "Builds a boolean flag when its value is true."
  @spec flag(String.t(), term()) :: [String.t()]
  def flag(flag, true), do: [flag]
  def flag(_flag, _value), do: []

  @doc "Repeats a flag once for each supplied value."
  @spec repeat(String.t(), Enumerable.t() | nil) :: [String.t()]
  def repeat(_flag, nil), do: []
  def repeat(flag, values), do: Enum.flat_map(values, &pair(flag, &1))

  @doc "Builds a flag whose value is a comma-separated list."
  @spec comma_pair(String.t(), [term()] | nil) :: [String.t()]
  def comma_pair(_flag, nil), do: []
  def comma_pair(_flag, []), do: []
  def comma_pair(flag, values), do: pair(flag, Enum.join(values, ","))

  @doc "Builds a flag/value pair, JSON-encoding non-string values."
  @spec json_pair(String.t(), term()) :: [String.t()]
  def json_pair(_flag, nil), do: []
  def json_pair(flag, value) when is_binary(value), do: pair(flag, value)
  def json_pair(flag, value), do: pair(flag, Jason.encode!(value))

  @doc "Builds a Codex `--config key=value` argument pair."
  @spec config(String.t(), String.t() | number() | boolean() | atom() | nil) :: [String.t()]
  def config(_key, nil), do: []
  def config(key, value), do: ["--config", "#{key}=#{encode_config(value)}"]

  defp encode_config(value) when is_binary(value), do: inspect(value)
  defp encode_config(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp encode_config(value) when is_atom(value), do: value |> Atom.to_string() |> inspect()
end
