defmodule Jido.Harness do
  @moduledoc """
  Unified, supervised interface for Amp, Claude, Codex, Gemini, Kimi Code, OpenCode, Grok, and Z.AI coding agents.

  Runs and direct CLI processes are owned by the application supervision tree, not by
  the caller that starts or consumes them.
  """

  alias Jido.Harness.{Error, ProcessManager, Registry, RequestResolver, RunManager, RunRequest}

  @version "2.0.0"

  @doc "Returns the package version."
  def version, do: @version

  @doc "Returns all built-in and configured adapter specs."
  def providers do
    Registry.providers()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.flat_map(fn provider ->
      case Registry.spec(provider) do
        {:ok, spec} -> [spec]
        _ -> []
      end
    end)
  end

  @doc "Returns the configured default provider, if one is set."
  def default_provider, do: Registry.default_provider()

  @doc "Starts a caller-independent provider run and returns its stable run ID."
  def start(provider, request, options \\ [])

  def start(provider, request, options) when is_atom(provider) and is_list(options) do
    with {:ok, request} <- prepare_request(provider, request, options),
         {:ok, id} <- RunManager.start(provider, request) do
      {:ok, id}
    end
  end

  def start(provider, _request, _options),
    do: {:error, Error.validation("provider must be an atom", details: %{provider: inspect(provider)})}

  @doc "Starts a request that contains a provider, or uses the explicitly configured default."
  def start_request(request, options \\ [])

  def start_request(%RunRequest{} = request, options) when is_list(options) do
    with {:ok, provider} <- request_provider(request.provider, options) do
      start(provider, request, options)
    end
  end

  def start_request(prompt, options) when is_binary(prompt) and is_list(options) do
    with {:ok, provider} <- request_provider(nil, options) do
      start(provider, prompt, options)
    end
  end

  def start_request(request, options) when (is_map(request) or is_list(request)) and is_list(options) do
    request_provider = provider_value(request)

    with {:ok, provider} <- request_provider(request_provider, options) do
      start(provider, request, options)
    end
  end

  def start_request(_request, _options),
    do: {:error, Error.validation("request must be a prompt, map, or RunRequest")}

  @doc "Returns a redacted snapshot of a supervised run."
  def info(run_id), do: RunManager.info(run_id)

  @doc "Lists runs, optionally filtering by provider or state."
  def list_runs(filters \\ []), do: RunManager.list(filters)

  @doc "Returns a cursor-driven stream that can attach or reattach to a run."
  def stream(run_id, options \\ []), do: RunManager.stream(run_id, options)

  @doc "Replays a bounded page of run events after a cursor."
  def replay(run_id, options \\ []), do: RunManager.replay(run_id, options)

  @doc "Waits for a run result without cancelling the run when the wait times out."
  def await(run_id, timeout \\ :infinity), do: RunManager.await(run_id, timeout)

  @doc "Requests cancellation of a running provider execution."
  def cancel(run_id), do: RunManager.cancel(run_id)

  @doc "Removes a terminal run and its retained journal."
  def prune(run_id), do: RunManager.prune(run_id)

  @doc "Starts a run and returns its ID together with a cursor-driven event stream."
  def run(provider, request, options \\ []) do
    with {:ok, run_id} <- start(provider, request, options),
         {:ok, event_stream} <- stream(run_id) do
      {:ok, run_id, event_stream}
    end
  end

  @doc "Runs a provider to completion. An await timeout does not cancel the run."
  def run_sync(provider, request, options \\ []) do
    await_timeout = Keyword.get(options, :await_timeout, :infinity)
    request_options = Keyword.delete(options, :await_timeout)

    with {:ok, run_id} <- start(provider, request, request_options) do
      await(run_id, await_timeout)
    end
  end

  @doc "Returns normalized provider installation, compatibility, and authentication status."
  def status(provider) do
    with {:ok, adapter} <- Registry.lookup(provider) do
      adapter.status(Registry.provider_config(provider))
    end
  end

  @doc "Performs or previews an adapter's explicit installation recipe."
  def install(provider, options \\ []) do
    with {:ok, adapter} <- Registry.lookup(provider) do
      if function_exported?(adapter, :install, 2) do
        adapter.install(Registry.provider_config(provider), options)
      else
        {:error, Error.new(:provider, "provider does not expose an installation recipe", provider: provider)}
      end
    end
  end

  @doc "Starts a caller-independent OS process from a structured specification."
  defdelegate start_process(spec), to: ProcessManager

  @doc "Returns a redacted managed-process snapshot."
  defdelegate info_process(process_id), to: ProcessManager

  @doc "Lists managed processes, optionally filtering by state."
  defdelegate list_processes(), to: ProcessManager
  defdelegate list_processes(filters), to: ProcessManager

  @doc "Returns a cursor-driven stream for managed-process events."
  defdelegate stream_process(process_id), to: ProcessManager
  defdelegate stream_process(process_id, options), to: ProcessManager

  @doc "Replays a bounded page of managed-process events."
  defdelegate replay_process(process_id), to: ProcessManager
  defdelegate replay_process(process_id, options), to: ProcessManager

  @doc "Waits for a managed process to terminate without cancelling it on timeout."
  defdelegate await_process(process_id), to: ProcessManager
  defdelegate await_process(process_id, timeout), to: ProcessManager

  @doc "Writes binary data to a managed process's standard input."
  defdelegate send_input(process_id, data), to: ProcessManager

  @doc "Closes a managed process's standard input."
  defdelegate close_input(process_id), to: ProcessManager

  @doc "Gracefully cancels a managed process using configured signal escalation."
  defdelegate cancel_process(process_id), to: ProcessManager

  @doc "Immediately kills a managed process group."
  defdelegate kill_process(process_id), to: ProcessManager

  @doc "Removes a terminal process and its retained journal."
  defdelegate prune_process(process_id), to: ProcessManager

  defp prepare_request(provider, %RunRequest{} = request, []), do: RequestResolver.resolve(provider, request)

  defp prepare_request(provider, %RunRequest{} = request, options) do
    attrs = request |> Map.from_struct() |> Map.merge(Map.new(options))
    RequestResolver.resolve(provider, attrs)
  end

  defp prepare_request(provider, prompt, options) when is_binary(prompt) do
    RequestResolver.resolve(provider, Map.merge(%{prompt: prompt}, Map.new(options)))
  end

  defp prepare_request(provider, request, options) when is_map(request) or is_list(request) do
    RequestResolver.resolve(provider, request |> Map.new() |> Map.merge(Map.new(options)))
  end

  defp prepare_request(_provider, request, _options),
    do: {:error, Error.validation("request must be a prompt, map, or RunRequest", details: %{value: inspect(request)})}

  defp request_provider(request_provider, options) do
    provider = provider_value(options) || request_provider || default_provider()

    case provider do
      provider when is_atom(provider) and not is_nil(provider) -> {:ok, provider}
      nil -> {:error, Error.new(:configuration, "no default provider is configured")}
      value -> {:error, Error.validation("provider must be an atom", details: %{provider: inspect(value)})}
    end
  end

  defp provider_value(values) when is_map(values) do
    Map.get(values, :provider) || Map.get(values, "provider")
  end

  defp provider_value(values) when is_list(values) do
    Keyword.get(values, :provider)
  end
end
