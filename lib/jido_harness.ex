defmodule Jido.Harness do
  @moduledoc """
  Unified, supervised interface for Amp, Claude, Codex, Gemini, Grok, Kimi Code,
  OpenCode, Pi, and Z.AI coding agents.

  Runs and direct CLI processes are owned by the application supervision tree, not by
  the caller that starts or consumes them.
  """

  alias Jido.Harness.{
    Error,
    ProcessManager,
    Registry,
    RequestResolver,
    RunManager,
    RunRequest,
    SessionManager,
    SessionRequest,
    TurnRequest
  }

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

  def start(provider, request, options) when is_atom(provider) do
    with {:ok, request} <- prepare_request(provider, request, options),
         {:ok, id} <- RunManager.start(provider, request) do
      {:ok, id}
    end
  end

  def start(provider, _request, _options),
    do: {:error, Error.validation("provider must be an atom", details: %{provider: inspect(provider)})}

  @doc "Starts a request that contains a provider, or uses the explicitly configured default."
  def start_request(request, options \\ [])

  def start_request(%RunRequest{} = request, options) do
    with {:ok, provider} <- request_provider(request.provider, options) do
      start(provider, request, options)
    end
  end

  def start_request(prompt, options) when is_binary(prompt) do
    with {:ok, provider} <- request_provider(nil, options) do
      start(provider, prompt, options)
    end
  end

  def start_request(request, options) when is_map(request) or is_list(request) do
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
    with {:ok, _options_map} <- options_map(options),
         await_timeout = Keyword.get(options, :await_timeout, :infinity),
         :ok <- Jido.Harness.Validation.await_timeout(await_timeout),
         request_options = Keyword.delete(options, :await_timeout),
         {:ok, run_id} <- start(provider, request, request_options) do
      await(run_id, await_timeout)
    end
  end

  @doc "Returns normalized provider installation, compatibility, and authentication status."
  def status(provider) do
    with {:ok, adapter} <- Registry.lookup(provider),
         {:ok, spec} <- Registry.spec(provider),
         {:ok, status} <- adapter.status(Registry.provider_config(provider)) do
      {:ok, %{status | session_transports: spec.session_transports}}
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

  @doc "Starts a caller-independent interactive provider session."
  def open_session(provider, request \\ %{}, options \\ [])

  def open_session(provider, request, options) when is_atom(provider) do
    with {:ok, request} <- prepare_session_request(provider, request, options),
         {:ok, session_id} <- SessionManager.start(provider, request) do
      {:ok, session_id}
    end
  end

  def open_session(provider, _request, _options),
    do: {:error, Error.validation("provider must be an atom", details: %{provider: inspect(provider)})}

  @doc "Returns a redacted snapshot of an interactive session."
  def info_session(session_id), do: SessionManager.info(session_id)

  @doc "Lists interactive sessions, optionally filtering by provider or state."
  def list_sessions(filters \\ []), do: SessionManager.list(filters)

  @doc "Returns a cursor-driven stream that can attach or reattach to a session."
  def stream_session(session_id, options \\ []), do: SessionManager.stream(session_id, options)

  @doc "Replays a bounded page of interactive session events."
  def replay_session(session_id, options \\ []), do: SessionManager.replay(session_id, options)

  @doc "Starts a turn when the session is idle and returns its stable turn ID."
  def send_message(session_id, input, options \\ []) do
    with {:ok, request} <- prepare_turn_request(input, options) do
      SessionManager.send_message(session_id, request)
    end
  end

  @doc "Queues a follow-up turn and returns its stable turn ID."
  def follow_up(session_id, input, options \\ []) do
    with {:ok, request} <- prepare_turn_request(input, options) do
      SessionManager.follow_up(session_id, request)
    end
  end

  @doc "Steers the active turn when the selected transport supports it."
  def steer(session_id, input, options \\ []) do
    with {:ok, request} <- prepare_turn_request(input, options) do
      SessionManager.steer(session_id, request)
    end
  end

  @doc "Waits for one turn without interrupting it when the wait times out."
  def await_turn(session_id, turn_id, timeout \\ :infinity),
    do: SessionManager.await_turn(session_id, turn_id, timeout)

  @doc "Interrupts the active turn while keeping its session available."
  def interrupt_turn(session_id, turn_id \\ :active), do: SessionManager.interrupt(session_id, turn_id)

  @doc "Responds to a pending normalized provider approval request."
  def respond_approval(session_id, request_id, response),
    do: SessionManager.respond_approval(session_id, request_id, response)

  @doc "Changes supported runtime session configuration."
  def configure_session(session_id, changes), do: SessionManager.configure(session_id, changes)

  @doc "Gracefully closes an interactive session."
  def close_session(session_id), do: SessionManager.close(session_id)

  @doc "Forcibly cancels an interactive session."
  def kill_session(session_id), do: SessionManager.kill(session_id)

  @doc "Removes a terminal session and its retained journal."
  def prune_session(session_id), do: SessionManager.prune(session_id)

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
    with {:ok, options} <- options_map(options) do
      attrs = request |> Map.from_struct() |> Map.merge(options)
      RequestResolver.resolve(provider, attrs)
    end
  end

  defp prepare_request(provider, prompt, options) when is_binary(prompt) do
    with {:ok, options} <- options_map(options) do
      RequestResolver.resolve(provider, Map.merge(%{prompt: prompt}, options))
    end
  end

  defp prepare_request(provider, request, options) when is_map(request) or is_list(request) do
    with {:ok, request} <- attributes_map(request, "request"),
         {:ok, options} <- options_map(options) do
      RequestResolver.resolve(provider, Map.merge(request, options))
    end
  end

  defp prepare_request(_provider, request, _options),
    do: {:error, Error.validation("request must be a prompt, map, or RunRequest", details: %{value: inspect(request)})}

  defp prepare_session_request(provider, %SessionRequest{} = request, options) do
    with {:ok, options} <- options_map(options) do
      attrs = request |> Map.from_struct() |> Map.merge(options) |> Map.put(:provider, provider)
      SessionRequest.new(attrs)
    end
  end

  defp prepare_session_request(provider, request, options) when is_map(request) or is_list(request) do
    with {:ok, request} <- attributes_map(request, "session request"),
         {:ok, options} <- options_map(options) do
      config_defaults = Registry.provider_config(provider) |> Map.get(:session_defaults, %{}) |> Map.new()

      attrs =
        config_defaults
        |> Map.merge(request)
        |> Map.merge(options)
        |> Map.put(:provider, provider)

      SessionRequest.new(attrs)
    end
  end

  defp prepare_session_request(_provider, request, _options),
    do: {:error, Error.validation("session request must be a map", details: %{value: inspect(request)})}

  defp prepare_turn_request(%TurnRequest{} = request, []), do: {:ok, request}

  defp prepare_turn_request(%TurnRequest{} = request, options),
    do:
      with(
        {:ok, options} <- options_map(options),
        do: request |> Map.from_struct() |> Map.merge(options) |> TurnRequest.new()
      )

  defp prepare_turn_request(input, []), do: TurnRequest.new(input)

  defp prepare_turn_request(input, options) when is_binary(input),
    do: with({:ok, options} <- options_map(options), do: options |> Map.put(:prompt, input) |> TurnRequest.new())

  defp prepare_turn_request(input, options) when is_map(input) or is_list(input) do
    with {:ok, input} <- attributes_map(input, "turn request"),
         {:ok, options} <- options_map(options) do
      input |> Map.merge(options) |> TurnRequest.new()
    end
  end

  defp prepare_turn_request(input, _options),
    do: {:error, Error.validation("turn request must be text or a map", details: %{value: inspect(input)})}

  defp request_provider(request_provider, options) do
    with {:ok, options} <- options_map(options) do
      provider = provider_value(options) || request_provider || default_provider()

      case provider do
        provider when is_atom(provider) and not is_nil(provider) -> {:ok, provider}
        nil -> {:error, Error.new(:configuration, "no default provider is configured")}
        value -> {:error, Error.validation("provider must be an atom", details: %{provider: inspect(value)})}
      end
    end
  end

  defp provider_value(values) when is_map(values) do
    Map.get(values, :provider) || Map.get(values, "provider")
  end

  defp provider_value(values) when is_list(values) do
    if Keyword.keyword?(values), do: Keyword.get(values, :provider), else: nil
  end

  defp options_map(options) when is_list(options) do
    if Keyword.keyword?(options),
      do: {:ok, Map.new(options)},
      else: {:error, Error.validation("options must be a keyword list")}
  end

  defp options_map(_options), do: {:error, Error.validation("options must be a keyword list")}

  defp attributes_map(attributes, _name) when is_map(attributes), do: {:ok, attributes}

  defp attributes_map(attributes, name) when is_list(attributes) do
    if Enum.all?(attributes, &match?({_, _}, &1)),
      do: {:ok, Map.new(attributes)},
      else: {:error, Error.validation("#{name} must be a map or key-value list")}
  end
end
