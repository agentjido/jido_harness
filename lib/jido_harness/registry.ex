defmodule Jido.Harness.Registry do
  @moduledoc "Built-in provider lookup with explicit application overrides."

  alias Jido.Harness.{AdapterSpec, Error}

  @builtins %{
    amp: Jido.Harness.Adapters.Amp,
    claude: Jido.Harness.Adapters.Claude,
    codex: Jido.Harness.Adapters.Codex,
    gemini: Jido.Harness.Adapters.Gemini,
    kimi: Jido.Harness.Adapters.Kimi,
    opencode: Jido.Harness.Adapters.OpenCode,
    grok: Jido.Harness.Adapters.Grok,
    zai: Jido.Harness.Adapters.Zai
  }

  @spec providers() :: %{optional(atom()) => module()}
  def providers do
    overrides = Application.get_env(:jido_harness, :providers, %{}) |> Map.new()
    Map.merge(@builtins, overrides)
  end

  @spec lookup(atom()) :: {:ok, module()} | {:error, Error.t()}
  def lookup(provider) when is_atom(provider) do
    with {:ok, adapter} <- Map.fetch(providers(), provider),
         true <- adapter_valid?(adapter) do
      {:ok, adapter}
    else
      :error ->
        {:error, Error.new(:configuration, "provider is not registered", provider: provider)}

      false ->
        {:error, Error.new(:configuration, "provider adapter does not implement the v2 contract", provider: provider)}
    end
  end

  def lookup(provider),
    do: {:error, Error.validation("provider must be an atom", details: %{provider: inspect(provider)})}

  @spec spec(atom()) :: {:ok, AdapterSpec.t()} | {:error, term()}
  def spec(provider) do
    with {:ok, adapter} <- lookup(provider),
         %AdapterSpec{} = spec <- adapter.spec(),
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

  def default_provider, do: Application.get_env(:jido_harness, :default_provider)

  def provider_config(provider) do
    :jido_harness
    |> Application.get_env(:provider_config, %{})
    |> Map.new()
    |> Map.get(provider, %{})
    |> Map.new()
  end

  defp adapter_valid?(adapter) when is_atom(adapter) do
    Code.ensure_loaded?(adapter) and
      Enum.all?([spec: 0, run: 2, status: 1], fn {name, arity} -> function_exported?(adapter, name, arity) end)
  end

  defp adapter_valid?(_adapter), do: false
end
