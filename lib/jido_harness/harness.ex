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
         Error.validation_error("No default provider is configured or discoverable", %{
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
         Error.validation_error("No default provider is configured or discoverable", %{
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
         {:ok, result} <- dispatch_run(module, request, opts) do
      {:ok, normalize_result_stream(result, provider)}
    end
  end

  @doc """
  Returns capabilities for a provider when available.
  """
  @spec capabilities(atom()) :: {:ok, map()} | {:error, term()}
  def capabilities(provider) when is_atom(provider) do
    with {:ok, module} <- Registry.lookup(provider) do
      cond do
        function_exported?(module, :capabilities, 0) ->
          {:ok, module.capabilities()}

        true ->
          {:ok,
           %Capabilities{
             streaming?: function_exported?(module, :run, 2) or function_exported?(module, :execute, 2),
             cancellation?: function_exported?(module, :cancel, 1)
           }}
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
    cond do
      function_exported?(module, :run_request, 2) ->
        safe_invoke(module, :run_request, [request, opts])

      function_exported?(module, :run, 2) ->
        case safe_invoke(module, :run, [request, opts]) do
          {:error, %FunctionClauseError{}} ->
            prompt_opts = Keyword.merge(request_to_opts(request), opts)
            safe_invoke(module, :run, [request.prompt, prompt_opts])

          other ->
            other
        end

      function_exported?(module, :execute, 2) ->
        prompt_opts = Keyword.merge(request_to_opts(request), opts)
        safe_invoke(module, :execute, [request.prompt, prompt_opts])

      true ->
        {:error,
         Error.execution_error("Provider module does not expose a supported run API", %{
           module: inspect(module)
         })}
    end
  end

  defp safe_invoke(module, function_name, args) do
    try do
      case apply(module, function_name, args) do
        {:ok, _} = ok -> ok
        {:error, _} = error -> error
        other -> {:ok, other}
      end
    rescue
      e in [FunctionClauseError, UndefinedFunctionError] ->
        {:error, e}
    end
  end

  defp normalize_result_stream(result, provider) do
    cond do
      Enumerable.impl_for(result) != nil ->
        Stream.map(result, &normalize_event(&1, provider))

      true ->
        [normalize_event(result, provider)]
    end
  end

  defp normalize_event(%Event{} = event, _provider), do: event

  defp normalize_event(%{type: type} = event, provider) do
    Event.new!(%{
      type: normalize_type(type),
      provider: event[:provider] || provider,
      session_id: event[:session_id],
      timestamp: event[:timestamp] || DateTime.utc_now() |> DateTime.to_iso8601(),
      payload: event[:payload] || %{},
      raw: event
    })
  rescue
    _ ->
      fallback_provider_event(event, provider)
  end

  defp normalize_event(%{"type" => type} = event, provider) do
    Event.new!(%{
      type: normalize_type(type),
      provider: Map.get(event, "provider", provider),
      session_id: Map.get(event, "session_id"),
      timestamp: Map.get(event, "timestamp") || DateTime.utc_now() |> DateTime.to_iso8601(),
      payload: Map.get(event, "payload", %{}),
      raw: event
    })
  rescue
    _ ->
      fallback_provider_event(event, provider)
  end

  defp normalize_event(text, provider) when is_binary(text) do
    Event.new!(%{
      type: :output_text_final,
      provider: provider,
      session_id: nil,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      payload: %{"text" => text},
      raw: text
    })
  end

  defp normalize_event(raw, provider), do: fallback_provider_event(raw, provider)

  defp fallback_provider_event(raw, provider) do
    Event.new!(%{
      type: :provider_event,
      provider: provider,
      session_id: nil,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      payload: %{"value" => inspect(raw)},
      raw: raw
    })
  end

  defp normalize_type(type) when is_atom(type), do: type

  defp normalize_type(type) when is_binary(type) do
    type
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  defp normalize_type(_), do: :provider_event

  defp request_to_opts(%RunRequest{} = request) do
    []
    |> maybe_put(:cwd, request.cwd)
    |> maybe_put(:model, request.model)
    |> maybe_put(:max_turns, request.max_turns)
    |> maybe_put(:timeout_ms, request.timeout_ms)
    |> maybe_put(:system_prompt, request.system_prompt)
    |> maybe_put(:allowed_tools, request.allowed_tools)
    |> maybe_put(:attachments, request.attachments)
    |> maybe_put(:metadata, request.metadata)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

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
