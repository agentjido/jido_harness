defmodule Jido.Harness.Registry do
  @moduledoc """
  Looks up provider adapter modules from configuration and runtime discovery.

  ## Configuration

      config :jido_harness, :providers, %{
        claude: Jido.Claude.Adapter,
        amp: Jido.Amp.Adapter
      }

      config :jido_harness, :default_provider, :claude
  """

  alias Jido.Harness.{Adapter, Error.ProviderNotFoundError}

  @required_callbacks [id: 0, capabilities: 0, run: 2]

  @doc """
  Returns all known provider bindings.

  Values are adapter modules that conform to `Jido.Harness.Adapter`.
  """
  @spec providers() :: %{optional(atom()) => module()}
  def providers do
    diagnostics().providers
  end

  @doc """
  Returns provider discovery/configuration diagnostics.

  Includes accepted and rejected candidates with reasons.
  """
  @spec diagnostics() :: %{
          discovered: %{optional(term()) => [map()]},
          configured: %{optional(term()) => map()},
          providers: %{optional(atom()) => module()}
        }
  def diagnostics do
    discovered_diagnostics = discovered_provider_diagnostics()
    configured_diagnostics = configured_provider_diagnostics()

    discovered =
      discovered_diagnostics
      |> Enum.reduce(%{}, fn {provider, entries}, acc ->
        case {provider, Enum.find(entries, &(&1.status == :accepted))} do
          {provider_atom, %{module: module}} when is_atom(provider_atom) ->
            Map.put(acc, provider_atom, module)

          _ ->
            acc
        end
      end)

    configured =
      configured_diagnostics
      |> Enum.reduce(%{}, fn
        {provider, %{status: :accepted, module: module}}, acc when is_atom(provider) ->
          Map.put(acc, provider, module)

        _, acc ->
          acc
      end)

    %{
      discovered: discovered_diagnostics,
      configured: configured_diagnostics,
      providers: Map.merge(discovered, configured)
    }
  end

  @doc """
  Looks up the runtime module for a given provider atom.

  Returns `{:ok, module}` or `{:error, Jido.Harness.Error.ProviderNotFoundError.t()}`.
  """
  @spec lookup(atom()) :: {:ok, module()} | {:error, term()}
  def lookup(provider) when is_atom(provider) do
    case Map.fetch(providers(), provider) do
      {:ok, adapter} ->
        {:ok, adapter}

      :error ->
        {:error,
         ProviderNotFoundError.exception(
           message: "Provider #{inspect(provider)} is not available",
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
  - first discovered/configured provider
  """
  @spec default_provider() :: atom() | nil
  def default_provider do
    configured = Application.get_env(:jido_harness, :default_provider)
    provider_map = providers()

    cond do
      is_atom(configured) and available?(configured) ->
        configured

      true ->
        ordered =
          provider_candidates()
          |> Map.keys()
          |> Enum.find(&Map.has_key?(provider_map, &1))

        ordered || provider_map |> Map.keys() |> Enum.sort() |> List.first()
    end
  end

  defp configured_provider_diagnostics do
    :jido_harness
    |> Application.get_env(:providers, %{})
    |> Enum.reduce(%{}, fn
      {provider, module}, acc when is_atom(provider) ->
        Map.put(acc, provider, candidate_diagnostic(module))

      {provider, module}, acc ->
        Map.put(acc, provider, %{
          module: module,
          status: :rejected,
          reason: :invalid_provider_key
        })
    end)
  end

  defp discovered_provider_diagnostics do
    provider_candidates()
    |> Enum.reduce(%{}, fn {provider, candidates}, acc ->
      entries =
        candidates
        |> normalize_candidates()
        |> Enum.map(&candidate_diagnostic/1)

      Map.put(acc, provider, entries)
    end)
  end

  defp normalize_candidates(candidates) when is_list(candidates), do: candidates
  defp normalize_candidates(candidate), do: [candidate]

  defp candidate_diagnostic(candidate) do
    case ensure_adapter_candidate(candidate) do
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

  defp ensure_adapter_candidate(module) when not is_atom(module), do: {:error, :invalid_module}

  defp ensure_adapter_candidate(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, :module_not_loaded}

      not adapter_behaviour_declared?(module) ->
        {:error, :missing_adapter_behaviour}

      true ->
        missing = missing_required_callbacks(module)

        if missing == [] do
          {:ok, module}
        else
          {:error, {:missing_callbacks, missing}}
        end
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

  defp provider_candidates do
    Application.get_env(:jido_harness, :provider_candidates, default_provider_candidates())
  end

  defp default_provider_candidates do
    %{
      codex: [Jido.Codex.Adapter, Jido.Codex],
      amp: [Jido.Amp.Adapter, Jido.Amp],
      claude: [Jido.Claude.Adapter, Jido.Claude],
      gemini: [Jido.Gemini.Adapter, Jido.Gemini],
      opencode: [Jido.OpenCode.Adapter, Jido.OpenCode]
    }
  end
end
