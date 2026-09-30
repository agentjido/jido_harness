defmodule Jido.Harness.Registry do
  @moduledoc "Built-in provider lookup with explicit application overrides."

  alias Jido.Harness.{AdapterSpec, Error}

  @builtins %{
    amp: Jido.Harness.Adapters.Amp,
    antigravity: Jido.Harness.Adapters.Antigravity,
    claude: Jido.Harness.Adapters.Claude,
    codex: Jido.Harness.Adapters.Codex,
    cursor: Jido.Harness.Adapters.Cursor,
    gemini: Jido.Harness.Adapters.Gemini,
    kimi: Jido.Harness.Adapters.Kimi,
    opencode: Jido.Harness.Adapters.OpenCode,
    grok: Jido.Harness.Adapters.Grok,
    pi: Jido.Harness.Adapters.Pi,
    zai: Jido.Harness.Adapters.Zai
  }

  @doc "Returns built-in providers with application overrides applied."
  @spec providers() :: %{optional(atom()) => module()}
  def providers do
    overrides = Application.get_env(:jido_harness, :providers, %{}) |> Map.new()
    Map.merge(@builtins, overrides)
  end

  @doc "Returns a registered adapter after checking its version 3 callbacks."
  @spec lookup(atom()) :: {:ok, module()} | {:error, Error.t()}
  def lookup(provider) when is_atom(provider) do
    with {:ok, adapter} <- Map.fetch(providers(), provider),
         true <- adapter_valid?(adapter) do
      {:ok, adapter}
    else
      :error ->
        {:error, Error.new(:configuration, "provider is not registered", provider: provider)}

      false ->
        {:error, Error.new(:configuration, "provider adapter does not implement the v3 contract", provider: provider)}
    end
  end

  def lookup(provider),
    do: {:error, Error.validation("provider must be an atom", details: %{provider: inspect(provider)})}

  @doc "Returns the validated specification for a registered provider."
  @spec spec(atom()) :: {:ok, AdapterSpec.t()} | {:error, term()}
  def spec(provider) do
    with {:ok, adapter} <- lookup(provider),
         %AdapterSpec{} = raw_spec <- adapter.spec(),
         {:ok, spec} <- AdapterSpec.new(Map.from_struct(raw_spec)),
         true <- spec.provider == provider do
      {:ok, spec}
    else
      {:error, %Error{}} = error ->
        error

      false ->
        {:error, Error.new(:configuration, "adapter spec provider does not match registry key", provider: provider)}

      other ->
        {:error,
         Error.new(:configuration, "adapter returned an invalid spec",
           provider: provider,
           details: %{value: inspect(other)}
         )}
    end
  end

  @doc "Returns the configured default provider, or `nil` when none is set."
  @spec default_provider() :: atom() | nil
  def default_provider, do: Application.get_env(:jido_harness, :default_provider)

  @doc "Returns provider configuration as a map, or an empty map when absent."
  @spec provider_config(atom()) :: map()
  def provider_config(provider) do
    :jido_harness
    |> Application.get_env(:provider_config, %{})
    |> Map.new()
    |> Map.get(provider, %{})
    |> Map.new()
  end

  defp adapter_valid?(adapter) when is_atom(adapter) do
    Code.ensure_loaded?(adapter) and
      Enum.all?([spec: 0, status: 1], fn {name, arity} -> function_exported?(adapter, name, arity) end)
  end

  defp adapter_valid?(_adapter), do: false
end
