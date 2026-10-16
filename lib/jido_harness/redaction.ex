defmodule Jido.Harness.Redaction do
  @moduledoc false

  @redacted "[REDACTED]"

  # "Bearer" in any case, spelled as character classes instead of with the
  # caseless flag: the flag leaves the regex engine without a first character
  # to look for, and it then takes seconds per megabyte of text that holds no
  # match, such as an image in base64.
  @bearer ~r/\b[Bb][Ee][Aa][Rr][Ee][Rr]\s+[^\s,;]+/
  @sensitive_key ~r/(^|_)(authorization|cookie|credential|password|secret|token|api_?key)($|_)/i

  @type prepared :: {:harness_redaction, [String.t()]}

  @doc false
  @spec prepare([String.t()]) :: prepared()
  def prepare(extra_secrets), do: {:harness_redaction, normalize_secrets(extra_secrets ++ system_secrets())}

  @doc "Removes sensitive fields and replaces known secret strings in nested values."
  @spec redact(term(), [String.t()] | prepared()) :: term()
  def redact(value, extra_secrets \\ [])
  def redact(value, {:harness_redaction, secrets}), do: do_redact(value, secrets)
  def redact(value, extra_secrets), do: redact(value, prepare(extra_secrets))

  @doc "Collects secret strings from environment keys that match sensitive names."
  @spec secrets_from_env(map()) :: [String.t()]
  def secrets_from_env(env) when is_map(env) do
    env
    |> Enum.filter(fn {key, _value} -> sensitive_key?(key) end)
    |> Enum.map(&elem(&1, 1))
    |> normalize_secrets()
  end

  defp do_redact(%_{} = struct, secrets), do: struct |> Map.from_struct() |> do_redact(secrets)

  defp do_redact(map, secrets) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key), do: {key, @redacted}, else: {key, do_redact(value, secrets)}
    end)
  end

  defp do_redact(list, secrets) when is_list(list), do: Enum.map(list, &do_redact(&1, secrets))

  defp do_redact(value, secrets) when is_binary(value) do
    value = Regex.replace(@bearer, value, "Bearer #{@redacted}")
    Enum.reduce(secrets, value, &String.replace(&2, &1, @redacted))
  end

  defp do_redact(value, _secrets), do: value

  defp system_secrets do
    case Process.get({__MODULE__, :system_secrets}) do
      nil ->
        secrets = System.get_env() |> secrets_from_env()
        Process.put({__MODULE__, :system_secrets}, secrets)
        secrets

      secrets ->
        secrets
    end
  end

  defp normalize_secrets(values) do
    values
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= 4))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp sensitive_key?(key) do
    key
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> String.match?(@sensitive_key)
  end
end
