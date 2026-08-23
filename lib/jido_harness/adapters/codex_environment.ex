defmodule Jido.Harness.Adapters.CodexEnvironment do
  @moduledoc false

  @cached_subscription_variables ~w(
    HOME CODEX_HOME PATH TMPDIR TEMP TMP SSL_CERT_FILE SSL_CERT_DIR
    NIX_SSL_CERT_FILE LANG LC_ALL
  )

  @doc false
  @spec cached_subscription() :: %{optional(String.t()) => String.t()}
  def cached_subscription do
    Enum.reduce(@cached_subscription_variables, %{}, fn name, env ->
      case System.get_env(name) do
        value when is_binary(value) and value != "" -> Map.put(env, name, value)
        _missing -> env
      end
    end)
  end
end
