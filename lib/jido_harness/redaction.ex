defmodule Jido.Harness.Redaction do
  @moduledoc false

  @redacted "[REDACTED]"
  @sensitive_key ~r/(^|_)(authorization|credential|password|secret|token|api_?key)($|_)/i

  @spec redact(term(), [String.t()]) :: term()
  def redact(value, extra_secrets \\ []) do
    secrets = normalize_secrets(extra_secrets ++ system_secrets())
    do_redact(value, secrets)
  end

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
    value = Regex.replace(~r/\bBearer\s+[^\s,;]+/i, value, "Bearer #{@redacted}")
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
