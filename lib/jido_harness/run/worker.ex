defmodule Jido.Harness.RunWorker do
  @moduledoc false
  use GenServer, restart: :temporary

  alias Jido.Harness.{Buffer, Error, RunInfo, RunResult, Signal, SignalLog, TextTail, Waiters}
  alias Jido.Harness.Adapter.Message
  alias Jido.Harness.Run.ACP

  def start_link({id, provider, request, adapter, acp_agent, session_request, turn_request, config}) do
    GenServer.start_link(
      __MODULE__,
      {id, provider, request, adapter, acp_agent, session_request, turn_request, config},
      name: {:via, Registry, {Jido.Harness.RunRegistry, id}}
    )
  end

  @impl true
  def init({id, provider, request, adapter, acp_agent, session_request, turn_request, config}) do
    Process.flag(:trap_exit, true)
    retention = Map.get(config, :retention, %{}) |> Map.new()
    memory_bytes = Map.get(retention, :memory_bytes, 1_048_576)
    signal_log = SignalLog.open(:run, id, retention)

    context = %{
      run_id: id,
      provider: provider,
      config: config,
      telemetry_context: %{run_id: id, provider: provider},
      process_manager: Jido.Harness.ProcessManager,
      run_owner: self(),
      adapter: adapter,
      acp_agent: acp_agent
    }

    state = %{
      id: id,
      provider: provider,
      request: request,
      secrets: Jido.Harness.Redaction.prepare(Jido.Harness.Redaction.secrets_from_env(request.env)),
      adapter: adapter,
      acp_agent: acp_agent,
      session_request: session_request,
      turn_request: turn_request,
      context: context,
      status: :starting,
      started_at: timestamp(),
      finished_at: nil,
      provider_session_id: request.provider_session_id,
      sequence: 0,
      buffer: SignalLog.new_buffer(memory_bytes),
      signal_log: signal_log,
      task: nil,
      adapter_started_at: nil,
      runtime_timer: nil,
      runtime_token: nil,
      idle_timer: nil,
      idle_token: nil,
      terminal_signal: nil,
      text_tail: TextTail.new(memory_bytes),
      final_text_tail: nil,
      structured_output: nil,
      usage: %{},
      error: nil,
      result: nil,
      waiters: %{}
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    started = Message.new!(%{type: :run_started, payload: %{"cwd" => state.request.cwd}})
    state = state |> Map.put(:status, :running) |> append(started)
    owner = self()

    :telemetry.execute([:jido, :harness, :run, :start], %{system_time: System.system_time()}, %{
      run_id: state.id,
      provider: state.provider
    })

    state = %{state | adapter_started_at: System.monotonic_time()}

    :telemetry.execute([:jido, :harness, :adapter, :start], %{system_time: System.system_time()}, %{
      run_id: state.id,
      provider: state.provider,
      adapter: state.adapter
    })

    task =
      Task.Supervisor.async(Jido.Harness.AdapterTaskSupervisor, fn ->
        invoke_acp(state.session_request, state.turn_request, state.context, owner)
      end)

    {:noreply, state |> Map.put(:task, task) |> schedule_runtime() |> schedule_idle()}
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, {:ok, info(state)}, state}

  def handle_call(:result, _from, %{result: %RunResult{} = result} = state), do: {:reply, {:ok, result}, state}
  def handle_call(:result, _from, state), do: {:reply, {:pending, info(state)}, state}

  def handle_call({:await, _request_ref}, _from, %{result: %RunResult{} = result} = state),
    do: {:reply, {:ok, result}, state}

  def handle_call({:await, request_ref}, from, state),
    do: {:noreply, %{state | waiters: Waiters.add(state.waiters, request_ref, from)}}

  def handle_call({:replay, cursor, limit}, _from, state) do
    {records, state} = replay_records(state, cursor, limit)
    {:reply, {:ok, records}, state}
  end

  def handle_call({:replay_page, cursor, limits}, _from, state) do
    {page, signal_log} =
      SignalLog.replay(state.signal_log, cursor, limits.max_signals, limits.max_bytes, &record_to_signal(state, &1))

    {:reply, {:ok, page}, %{state | signal_log: signal_log}}
  end

  def handle_call(:cancel, _from, %{result: %RunResult{}} = state), do: {:reply, :ok, state}

  def handle_call(:cancel, _from, %{terminal_signal: %Jido.Signal{}} = state) do
    state = state |> stop_adapter() |> finalize_from_terminal()
    {:reply, :ok, state}
  end

  def handle_call(:cancel, _from, state) when state.status in [:starting, :running] do
    state =
      state
      |> stop_adapter()
      |> append_terminal(:run_cancelled, %{"reason" => "cancelled"})
      |> finalize(:cancelled, nil)

    {:reply, :ok, state}
  end

  def handle_call(:cancel, _from, state), do: {:reply, :ok, state}

  def handle_call(:prune, _from, state) when state.status in [:completed, :failed, :cancelled] do
    case SignalLog.remove(state.signal_log) do
      :ok -> {:stop, :normal, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:prune, _from, state), do: {:reply, {:error, :running}, state}

  @impl true
  def handle_cast({:cancel_await, request_ref}, state),
    do: {:noreply, %{state | waiters: Waiters.cancel(state.waiters, request_ref)}}

  @impl true
  def handle_info({:adapter_message, %Message{} = message}, %{terminal_signal: nil} = state) do
    state = schedule_idle(state)

    state =
      if message.provider_session_id,
        do: %{state | provider_session_id: message.provider_session_id},
        else: state

    message = provider_start_message(message)
    state = append(state, message)

    state =
      if Signal.run_terminal?(state.buffer |> Buffer.signals() |> List.last()),
        do: %{state | terminal_signal: state.buffer |> Buffer.signals() |> List.last()},
        else: state

    {:noreply, state}
  end

  def handle_info({:adapter_message, _message}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}

    state =
      case result do
        :ok -> finish_success(state)
        {:error, reason} -> finish_error(state, reason)
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    {:noreply, state |> Map.put(:task, nil) |> finish_error(reason)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, %{state | waiters: Waiters.drop_monitor(state.waiters, monitor)}}
  end

  def handle_info({:run_timeout, :runtime, token}, %{runtime_token: token, status: status} = state)
      when status in [:starting, :running] do
    {:noreply, timeout(state, :runtime)}
  end

  def handle_info({:run_timeout, :idle, token}, %{idle_token: token, status: status} = state)
      when status in [:starting, :running] do
    {:noreply, timeout(state, :idle)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp provider_start_message(%Message{type: :run_started} = message) do
    %{message | type: :provider_message, payload: Map.put(message.payload, "kind", "provider_run_started")}
  end

  defp provider_start_message(%Message{} = message), do: message

  @impl true
  def terminate(_reason, state) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    SignalLog.close(state.signal_log)
  end

  defp invoke_acp(session_request, turn_request, context, owner) do
    try do
      case ACP.stream(session_request, turn_request, context) do
        {:ok, stream} ->
          if Enumerable.impl_for(stream) do
            Enum.each(stream, fn
              %Message{} = message -> send(owner, {:adapter_message, message})
              other -> throw({:invalid_adapter_message, other})
            end)

            :ok
          else
            {:error, Error.execution("ACP run did not return an enumerable", provider: context.provider)}
          end

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error,
           Error.execution("ACP run returned an invalid result",
             provider: context.provider,
             details: %{value: inspect(other)}
           )}
      end
    rescue
      exception ->
        {:error,
         Error.execution("ACP run raised",
           provider: context.provider,
           cause: exception,
           details: %{message: Exception.message(exception)}
         )}
    catch
      kind, reason ->
        {:error, Error.execution("ACP run terminated", provider: context.provider, cause: {kind, reason})}
    end
  end

  defp append(state, %Message{} = message) do
    {:ok, signal} =
      Signal.from_adapter(message, :run, state.id, state.provider, state.sequence + 1, state.request.metadata)

    {buffer, signal_log} = SignalLog.append(state.buffer, state.signal_log, signal, state.secrets)

    :telemetry.execute([:jido, :harness, :run, :signal], %{count: 1}, %{
      run_id: state.id,
      provider: state.provider,
      type: signal.type
    })

    state
    |> Map.put(:sequence, Signal.sequence(signal))
    |> Map.put(:buffer, buffer)
    |> Map.put(:signal_log, signal_log)
    |> accumulate(signal)
  end

  defp append_terminal(%{terminal_signal: %Jido.Signal{}} = state, _type, _payload), do: state

  defp append_terminal(state, type, payload) do
    message =
      Message.new!(%{
        type: type,
        provider_session_id: state.provider_session_id,
        payload: payload
      })

    state = append(state, message)
    %{state | terminal_signal: state.buffer |> Buffer.signals() |> List.last()}
  end

  defp accumulate(state, %Jido.Signal{} = signal) do
    accumulate(state, Signal.kind(signal), signal.data["payload"] || %{})
  end

  defp accumulate(state, :output_text_delta, payload) do
    case Map.get(payload, "text") do
      text when is_binary(text) -> %{state | text_tail: TextTail.append(state.text_tail, text)}
      _ -> state
    end
  end

  defp accumulate(state, :output_text_final, payload) do
    case Map.get(payload, "text") do
      text when is_binary(text) -> %{state | final_text_tail: TextTail.replace(state.text_tail, text)}
      _ -> state
    end
  end

  defp accumulate(state, :structured_output, payload) do
    %{state | structured_output: Map.take(payload, ["schema_id", "value"])}
  end

  defp accumulate(state, :usage, payload), do: %{state | usage: Map.merge(state.usage, payload)}
  defp accumulate(state, _kind, _payload), do: state

  defp finish_success(%{terminal_signal: nil} = state) do
    state |> append_terminal(:run_completed, %{}) |> finalize(:completed, nil)
  end

  defp finish_success(%{terminal_signal: %Jido.Signal{} = signal} = state) do
    case Signal.kind(signal) do
      :run_completed -> finalize(state, :completed, nil)
      :run_cancelled -> finalize(state, :cancelled, nil)
      :run_failed -> finalize_from_terminal(state)
    end
  end

  defp finish_error(%{terminal_signal: nil} = state, reason) do
    error = normalize_error(state, reason)
    state |> append_terminal(:run_failed, %{"error" => Exception.message(error)}) |> finalize(:failed, error)
  end

  defp finish_error(%{terminal_signal: %Jido.Signal{}} = state, _reason), do: finalize_from_terminal(state)

  defp finalize(state, status, error) do
    signals = Buffer.signals(state.buffer)
    text = state.final_text_tail || state.text_tail

    result = %RunResult{
      run_id: state.id,
      provider: state.provider,
      provider_session_id: state.provider_session_id,
      status: status,
      text: Jido.Harness.TextTail.text(text),
      text_truncated?: text.truncated?,
      structured_output: state.structured_output,
      usage: state.usage,
      signals: signals,
      metadata: state.request.metadata,
      error: error
    }

    cancel_timer(state.runtime_timer)
    cancel_timer(state.idle_timer)
    state = stop_adapter_telemetry(state, status)

    :telemetry.execute([:jido, :harness, :run, :stop], %{count: 1}, %{
      run_id: state.id,
      provider: state.provider,
      status: status
    })

    waiters = Waiters.reply_all(state.waiters, {:ok, result})

    %{
      state
      | status: status,
        error: error,
        finished_at: timestamp(),
        result: result,
        adapter_started_at: nil,
        runtime_timer: nil,
        idle_timer: nil,
        waiters: waiters
    }
  end

  defp normalize_error(state, %Error{} = error) do
    %{error | provider: error.provider || state.provider, run_id: error.run_id || state.id}
  end

  defp normalize_error(state, reason),
    do: Error.execution("provider run failed", provider: state.provider, run_id: state.id, cause: reason)

  defp stop_adapter(state) do
    if state.task, do: Task.shutdown(state.task, 5_000)
    %{state | task: nil}
  end

  defp timeout(%{terminal_signal: %Jido.Signal{}} = state, _kind) do
    state |> stop_adapter() |> finalize_from_terminal()
  end

  defp timeout(state, kind) do
    error = Error.new(:timeout, "#{kind} timeout exceeded", provider: state.provider, run_id: state.id)

    state
    |> stop_adapter()
    |> append_terminal(:run_failed, %{"error" => error.message, "timeout" => Atom.to_string(kind)})
    |> finalize(:failed, error)
  end

  defp finalize_from_terminal(%{terminal_signal: %Jido.Signal{} = signal} = state) do
    case Signal.kind(signal) do
      :run_completed -> finalize(state, :completed, nil)
      :run_cancelled -> finalize(state, :cancelled, nil)
      :run_failed -> finalize_failed_signal(state, signal)
    end
  end

  defp finalize_failed_signal(state, signal) do
    payload = signal.data["payload"] || %{}

    message =
      case Map.get(payload, "error") do
        value when is_binary(value) and value != "" -> value
        _value -> "provider reported failure"
      end

    details = failure_details(payload)
    error = state.error || Error.execution(message, provider: state.provider, run_id: state.id, details: details)
    finalize(state, :failed, error)
  end

  defp failure_details(payload) do
    details = if is_binary(payload["failure_kind"]), do: %{failure_kind: payload["failure_kind"]}, else: %{}
    if is_map(payload["process"]), do: Map.put(details, :process, payload["process"]), else: details
  end

  defp schedule_runtime(%{request: %{runtime_timeout_ms: :infinity}} = state), do: state

  defp schedule_runtime(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:run_timeout, :runtime, token}, state.request.runtime_timeout_ms)
    %{state | runtime_timer: timer, runtime_token: token}
  end

  defp schedule_idle(%{request: %{idle_timeout_ms: :infinity}} = state), do: state

  defp schedule_idle(state) do
    cancel_timer(state.idle_timer)
    token = make_ref()
    timer = Process.send_after(self(), {:run_timeout, :idle, token}, state.request.idle_timeout_ms)
    %{state | idle_timer: timer, idle_token: token}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: true, info: false)

  defp stop_adapter_telemetry(%{adapter_started_at: nil} = state, _status), do: state

  defp stop_adapter_telemetry(state, status) do
    :telemetry.execute(
      [:jido, :harness, :adapter, :stop],
      %{duration: System.monotonic_time() - state.adapter_started_at},
      %{run_id: state.id, provider: state.provider, adapter: state.adapter, status: status}
    )

    %{state | adapter_started_at: nil}
  end

  defp replay_records(state, cursor, limit) do
    {page, signal_log} = SignalLog.replay(state.signal_log, cursor, limit, 1_048_576, &record_to_signal(state, &1))
    signals = SignalLog.signals(page, &Function.identity/1, &gap_signal(state, &1))
    {signals, %{state | signal_log: signal_log}}
  end

  defp gap_signal(state, gap) do
    Signal.replay_gap(:run, state.id, gap, state.request.metadata)
  end

  defp record_to_signal(_state, %Jido.Signal{} = signal), do: signal

  defp record_to_signal(_state, %{"format_version" => 2, "signal" => wire}) do
    {:ok, signal} = Jido.Signal.Catalog.decode(Signal.catalog(), wire)
    signal
  end

  defp info(state) do
    %RunInfo{
      run_id: state.id,
      provider: state.provider,
      state: state.status,
      started_at: state.started_at,
      finished_at: state.finished_at,
      provider_session_id: state.provider_session_id,
      error: state.error,
      journal_dir: SignalLog.dir(state.signal_log),
      replay_store: SignalLog.info(state.signal_log),
      output_cursor: state.sequence,
      metadata: state.request.metadata
    }
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
