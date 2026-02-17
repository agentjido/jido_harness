defmodule Jido.Harness.Registry do
  @moduledoc """
  Looks up provider adapter modules from configuration and runtime discovery.

  ## Configuration

      config :jido_harness, :providers, %{
        claude: Jido.Harness.Adapters.Claude,
        amp: Jido.Harness.Adapters.Amp
      }

      config :jido_harness, :default_provider, :claude
  """

  alias Jido.Harness.Error.ProviderNotFoundError

  @doc """
  Returns all known provider bindings.

  Values are module names that can handle provider execution.
  """
  @spec providers() :: %{optional(atom()) => module()}
  def providers do
    discovered = discover_providers()
    configured = configured_providers()
    Map.merge(discovered, configured)
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

  defp configured_providers do
    :jido_harness
    |> Application.get_env(:providers, %{})
    |> Enum.reduce(%{}, fn
      {provider, module}, acc when is_atom(provider) and is_atom(module) ->
        Map.put(acc, provider, module)

      _other, acc ->
        acc
    end)
  end

  defp discover_providers do
    provider_candidates()
    |> Enum.reduce(%{}, fn {provider, modules}, acc ->
      case Enum.find(modules, &provider_module?/1) do
        nil -> acc
        module -> Map.put(acc, provider, module)
      end
    end)
  end

  defp provider_candidates do
    Application.get_env(:jido_harness, :provider_candidates, default_provider_candidates())
  end

  defp provider_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      (function_exported?(module, :run_request, 2) or
         function_exported?(module, :run, 2) or
         function_exported?(module, :execute, 2))
  end

  defp provider_module?(_), do: false

  defp default_provider_candidates do
    %{
      codex: [Module.concat([Jido, Codex, Adapter]), Module.concat([Jido, Codex]), Module.concat([JidoCodex, Adapter])],
      amp: [Module.concat([Jido, Amp, Adapter]), Module.concat([Jido, Amp]), Module.concat([JidoAmp, Adapter])],
      claude: [
        Module.concat([Jido, Claude, Adapter]),
        Module.concat([JidoClaude, Adapter]),
        Module.concat([JidoClaude])
      ],
      gemini: [
        Module.concat([Jido, Gemini, Adapter]),
        Module.concat([JidoGemini, Adapter]),
        Module.concat([JidoGemini])
      ]
    }
  end
end
