defmodule JidoHarness.Registry do
  @moduledoc """
  Looks up provider adapter modules from application configuration.

  ## Configuration

      config :jido_harness, :providers, %{
        claude: JidoHarness.Adapters.Claude,
        amp: JidoHarness.Adapters.Amp
      }

      config :jido_harness, :default_provider, :claude
  """

  @doc """
  Looks up the adapter module for a given provider atom.

  Returns `{:ok, module}` or `{:error, JidoHarness.Error.ProviderNotFoundError.t()}`.
  """
  @spec lookup(atom()) :: {:ok, module()} | {:error, term()}
  def lookup(provider) when is_atom(provider) do
    providers = Application.get_env(:jido_harness, :providers, %{})

    case Map.fetch(providers, provider) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, JidoHarness.Error.ProviderNotFoundError.exception(message: "Provider #{inspect(provider)} is not configured", provider: provider)}
    end
  end

  @doc """
  Returns the default provider atom from application config.
  """
  @spec default_provider() :: atom() | nil
  def default_provider do
    Application.get_env(:jido_harness, :default_provider)
  end
end
