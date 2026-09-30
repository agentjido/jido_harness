defmodule Jido.Harness.Adapters.Codex.Isolation do
  @moduledoc false

  alias Jido.Harness.{Error, SessionRequest}

  @controls [
    ephemeral: {"CODEX_EPHEMERAL", "ephemeral"},
    ignore_user_config: {"CODEX_IGNORE_USER_CONFIG", "ignoreUserConfig"}
  ]

  @doc false
  @spec validate(SessionRequest.t()) :: :ok | {:error, Error.t()}
  def validate(request) do
    with {:ok, options} <- options(request.provider_options) do
      if options[:ephemeral] == true and is_binary(request.provider_session_id),
        do: {:error, Error.validation("ephemeral Codex execution cannot resume a session", provider: :codex)},
        else: :ok
    end
  end

  @doc false
  @spec environment(SessionRequest.t()) :: {:ok, map()} | {:error, Error.t()}
  def environment(request) do
    with {:ok, options} <- options(request.provider_options) do
      env =
        Map.new(options, fn {key, enabled} ->
          {variable, _capability} = Keyword.fetch!(@controls, key)
          {variable, if(enabled, do: "1", else: "0")}
        end)

      {:ok, env}
    end
  end

  @doc false
  @spec validate_capabilities(SessionRequest.t(), map()) :: :ok | {:error, Error.t()}
  def validate_capabilities(request, capabilities) do
    with {:ok, options} <- options(request.provider_options) do
      applied = get_in(capabilities, ["_meta", "codex", "isolation"]) || %{}

      case Enum.find(options, fn {key, enabled} ->
             {_variable, capability} = Keyword.fetch!(@controls, key)
             enabled and applied[capability] != true
           end) do
        nil ->
          :ok

        {key, _} ->
          {:error,
           Error.new(:configuration, "Codex ACP adapter cannot apply the requested isolation control",
             provider: :codex,
             details: %{option: key, capability: :isolation}
           )}
      end
    end
  end

  defp options(options) do
    Enum.reduce_while(@controls, {:ok, %{}}, fn {key, _mapping}, {:ok, normalized} ->
      string = Atom.to_string(key)
      value = Map.get(options, key, Map.get(options, string, :absent))

      cond do
        Map.has_key?(options, key) and Map.has_key?(options, string) ->
          {:halt,
           {:error, Error.validation("duplicate Codex isolation option", provider: :codex, details: %{option: key})}}

        value == :absent ->
          {:cont, {:ok, normalized}}

        is_boolean(value) ->
          {:cont, {:ok, Map.put(normalized, key, value)}}

        true ->
          {:halt,
           {:error,
            Error.validation("Codex isolation options must be booleans", provider: :codex, details: %{option: key})}}
      end
    end)
  end
end
