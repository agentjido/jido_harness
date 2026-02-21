defmodule Jido.Harness do
  @moduledoc """
  Normalized Elixir protocol for CLI AI coding agents.

  Jido.Harness provides a unified facade for running CLI coding agents (Amp, Claude Code,
  Codex, Gemini CLI, etc.) through a consistent API. Provider adapter packages implement
  the `Jido.Harness.Adapter` behaviour to normalize each agent's CLI interface.

  ## Usage

      {:ok, events} = Jido.Harness.run(:claude, "fix the bug", cwd: "/my/project")

  """

  alias Jido.Harness.{Capabilities, Error, Event, Provider, Registry, RunRequest}

  @request_keys [
    :cwd,
    :model,
    :max_turns,
    :timeout_ms,
    :system_prompt,
    :allowed_tools,
    :attachments,
    :metadata
  ]

  @doc """
  Returns available providers.
  """
  @spec providers() :: [Provider.t()]
  def providers do
    Registry.providers()
    |> Enum.map(fn {id, module} ->
      Provider.new!(%{
        id: id,
        name: provider_name(id, module),
        docs_url: docs_url_for(id)
      })
    end)
  end

  @doc """
  Returns the configured or discovered default provider.
  """
  @spec default_provider() :: atom() | nil
  def default_provider, do: Registry.default_provider()

  @doc """
  Runs a prompt using the default provider.
  """
  @spec run(String.t(), keyword()) :: {:ok, Enumerable.t(Event.t())} | {:error, term()}
  def run(prompt, opts) when is_binary(prompt) and is_list(opts) do
    case Registry.default_provider() do
      nil ->
        {:error,
         Error.validation_error("No default provider is configured", %{
           field: :default_provider
         })}

      provider ->
        run(provider, prompt, opts)
    end
  end

  @doc """
  Runs a CLI coding agent with the given prompt.

  Looks up the adapter for `provider` from the registry and delegates to its `run/2` callback.

  ## Parameters

    * `provider` - Atom identifying the provider (e.g. `:claude`, `:amp`, `:codex`)
    * `prompt` - The prompt string to send to the agent
    * `opts` - Keyword list of options passed to `RunRequest.new/1`

  ## Returns

    * `{:ok, Enumerable.t()}` - A stream of `Jido.Harness.Event` structs
    * `{:error, term()}` - On failure
  """
  @spec run(atom(), String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def run(provider, prompt, opts \\ []) do
    request_opts = Keyword.take(opts, @request_keys)
    adapter_opts = Keyword.drop(opts, @request_keys)

    with {:ok, request} <- RunRequest.new(Map.new([{:prompt, prompt} | request_opts])) do
      run_request(provider, request, adapter_opts)
    end
  end

  @doc """
  Runs a pre-built `%Jido.Harness.RunRequest{}` against the default provider.
  """
  @spec run_request(RunRequest.t(), keyword()) :: {:ok, Enumerable.t(Event.t())} | {:error, term()}
  def run_request(%RunRequest{} = request, opts \\ []) when is_list(opts) do
    case Registry.default_provider() do
      nil ->
        {:error,
         Error.validation_error("No default provider is configured", %{
           field: :default_provider
         })}

      provider ->
        run_request(provider, request, opts)
    end
  end

  @doc """
  Runs a pre-built `%Jido.Harness.RunRequest{}` against a specific provider.
  """
  @spec run_request(atom(), RunRequest.t(), keyword()) :: {:ok, Enumerable.t(Event.t())} | {:error, term()}
  def run_request(provider, %RunRequest{} = request, opts) when is_atom(provider) and is_list(opts) do
    with {:ok, module} <- Registry.lookup(provider),
         {:ok, stream} <- dispatch_run(module, request, opts) do
      {:ok, Stream.map(stream, &ensure_event!/1)}
    end
  end

  @doc """
  Returns capabilities for a provider when available.
  """
  @spec capabilities(atom()) :: {:ok, Capabilities.t()} | {:error, term()}
  def capabilities(provider) when is_atom(provider) do
    with {:ok, module} <- Registry.lookup(provider) do
      if function_exported?(module, :capabilities, 0) do
        case module.capabilities() do
          %Capabilities{} = caps ->
            {:ok, caps}

          other ->
            {:error,
             Error.execution_error("Provider adapter must return %Jido.Harness.Capabilities{}", %{
               provider: provider,
               value: inspect(other)
             })}
        end
      else
        {:error,
         Error.execution_error("Provider adapter does not expose capabilities/0", %{
           provider: provider,
           module: inspect(module)
         })}
      end
    end
  end

  @doc """
  Cancels an active session for a provider, if supported.
  """
  @spec cancel(atom(), String.t()) :: :ok | {:error, term()}
  def cancel(provider, session_id) when is_atom(provider) and is_binary(session_id) and session_id != "" do
    with {:ok, module} <- Registry.lookup(provider) do
      if function_exported?(module, :cancel, 1) do
        module.cancel(session_id)
      else
        {:error,
         Error.execution_error("Provider does not support cancellation", %{
           provider: provider
         })}
      end
    end
  end

  def cancel(_provider, session_id) do
    {:error, Error.validation_error("session_id must be a non-empty string", %{value: session_id})}
  end

  defp dispatch_run(module, %RunRequest{} = request, opts) do
    if function_exported?(module, :run, 2) do
      safe_invoke(module, :run, [request, opts])
    else
      {:error,
       Error.execution_error("Provider adapter does not expose run/2", %{
         module: inspect(module)
       })}
    end
  end

  defp safe_invoke(module, function_name, args) do
    try do
      case apply(module, function_name, args) do
        {:ok, stream} = ok ->
          if Enumerable.impl_for(stream) != nil do
            ok
          else
            {:error,
             Error.execution_error("Provider run/2 must return an Enumerable stream", %{
               module: inspect(module),
               value: inspect(stream)
             })}
          end

        {:error, _} = error ->
          error

        other ->
          {:error,
           Error.execution_error("Provider run/2 must return {:ok, stream} | {:error, term()}", %{
             module: inspect(module),
             value: inspect(other)
           })}
      end
    rescue
      e in [FunctionClauseError, UndefinedFunctionError, ArgumentError] ->
        {:error,
         Error.execution_error("Provider run/2 invocation failed", %{
           module: inspect(module),
           error: Exception.message(e)
         })}
    end
  end

  defp ensure_event!(%Event{} = event), do: event

  defp ensure_event!(other) do
    raise ArgumentError,
          "Provider stream must emit %Jido.Harness.Event{} values, got: #{inspect(other)}"
  end

  defp provider_name(id, module) do
    module_name =
      module
      |> inspect()
      |> String.trim_leading("Elixir.")

    "#{id} (#{module_name})"
  end

  defp docs_url_for(:amp), do: "https://hex.pm/packages/jido_amp"
  defp docs_url_for(:claude), do: "https://hex.pm/packages/jido_claude"
  defp docs_url_for(:codex), do: "https://hex.pm/packages/jido_codex"
  defp docs_url_for(:gemini), do: "https://hex.pm/packages/jido_gemini"
  defp docs_url_for(_), do: nil
end
