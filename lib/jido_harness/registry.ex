defmodule Jido.Harness.Registry do
  @moduledoc """
  Looks up provider adapter modules from explicit application configuration.

  ## Configuration

      config :jido_harness, :providers, %{
        claude: Jido.Claude.Adapter,
        amp: Jido.Amp.Adapter
      }

      config :jido_harness, :default_provider, :claude
  """

  alias Jido.Harness.{Adapter, Error.ProviderNotFoundError}

  @required_callbacks [id: 0, capabilities: 0, run: 2, runtime_contract: 0]

  @type diagnostic_entry :: %{
          module: term(),
          status: :accepted | :rejected,
          reason:
            atom()
            | {:missing_callbacks, [{atom(), non_neg_integer()}]}
            | {:id_mismatch, atom()}
            | {:id_invalid, term()}
            | {:id_unavailable, term()}
        }

  @doc """
  Returns all configured provider bindings that pass adapter conformance checks.
  """
  @spec providers() :: %{optional(atom()) => module()}
  def providers do
    diagnostics().providers
  end

  @doc """
  Returns provider configuration diagnostics.
  """
  @spec diagnostics() :: %{
          configured: %{optional(term()) => diagnostic_entry()},
          providers: %{optional(atom()) => module()}
        }
  def diagnostics do
    configured_diagnostics = configured_provider_diagnostics()

    providers =
      configured_diagnostics
      |> Enum.reduce(%{}, fn
        {provider, %{status: :accepted, module: module}}, acc when is_atom(provider) ->
          Map.put(acc, provider, module)

        _, acc ->
          acc
      end)

    %{
      configured: configured_diagnostics,
      providers: providers
    }
  end

  @doc """
  Looks up the adapter module for a provider atom.
  """
  @spec lookup(atom()) :: {:ok, module()} | {:error, term()}
  def lookup(provider) when is_atom(provider) do
    case Map.fetch(providers(), provider) do
      {:ok, adapter} ->
        {:ok, adapter}

      :error ->
        {:error,
         ProviderNotFoundError.exception(
           message:
             "Provider #{inspect(provider)} is not available (explicit config required in :jido_harness, :providers)",
           provider: provider
         )}
    end
  end

  @doc """
  Returns true if the provider is available.
  """
  @spec available?(atom()) :: boolean()
  def available?(provider) when is_atom(provider), do: match?({:ok, _}, lookup(provider))

  @doc """
  Returns the default provider atom.

  Resolution order:
  - `:jido_harness, :default_provider` (if available)
  - first configured provider key in sorted order
  """
  @spec default_provider() :: atom() | nil
  def default_provider do
    configured = Application.get_env(:jido_harness, :default_provider)
    provider_map = providers()

    cond do
      is_atom(configured) and Map.has_key?(provider_map, configured) ->
        configured

      true ->
        provider_map |> Map.keys() |> Enum.sort() |> List.first()
    end
  end

  defp configured_provider_diagnostics do
    :jido_harness
    |> Application.get_env(:providers, %{})
    |> Enum.reduce(%{}, fn
      {provider, module}, acc when is_atom(provider) ->
        Map.put(acc, provider, candidate_diagnostic(provider, module))

      {provider, module}, acc ->
        Map.put(acc, provider, %{
          module: module,
          status: :rejected,
          reason: :invalid_provider_key
        })
    end)
  end

  defp candidate_diagnostic(provider, candidate) do
    case ensure_adapter_candidate(provider, candidate) do
      {:ok, module} ->
        %{
          module: module,
          status: :accepted,
          reason: :ok
        }

      {:error, reason} ->
        %{
          module: candidate,
          status: :rejected,
          reason: reason
        }
    end
  end

  defp ensure_adapter_candidate(_provider, module) when not is_atom(module), do: {:error, :invalid_module}

  defp ensure_adapter_candidate(provider, module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, :module_not_loaded}

      not adapter_behaviour_declared?(module) ->
        {:error, :missing_adapter_behaviour}

      true ->
        missing = missing_required_callbacks(module)

        if missing != [] do
          {:error, {:missing_callbacks, missing}}
        else
          ensure_provider_id_match(provider, module)
        end
    end
  end

  defp ensure_provider_id_match(provider, module) do
    try do
      case module.id() do
        ^provider ->
          {:ok, module}

        value when is_atom(value) ->
          {:error, {:id_mismatch, value}}

        value ->
          {:error, {:id_invalid, value}}
      end
    rescue
      reason ->
        {:error, {:id_unavailable, reason}}
    end
  end

  defp adapter_behaviour_declared?(module) when is_atom(module) do
    module
    |> module_behaviours()
    |> Enum.member?(Adapter)
  end

  defp module_behaviours(module) do
    module
    |> module_attributes()
    |> Keyword.get(:behaviour, [])
  end

  defp module_attributes(module) do
    module.module_info(:attributes)
  rescue
    _ -> []
  end

  defp missing_required_callbacks(module) do
    @required_callbacks
    |> Enum.reject(fn {function, arity} -> function_exported?(module, function, arity) end)
  end
end
