defmodule Jido.Harness.RunWorker do
  @moduledoc false
  use GenServer, restart: :temporary

  alias Jido.Harness.{Buffer, Error, Event, EventLog, RunInfo, RunResult, TextTail}

  def start_link({id, provider, request, adapter, config}) do
    GenServer.start_link(
      __MODULE__,
      {id, provider, request, adapter, config},
      name: {:via, Registry, {Jido.Harness.RunRegistry, id}}
    )
  end

  @impl true
  def init({id, provider, request, adapter, config}) do
    Process.flag(:trap_exit, true)
    retention = Map.get(config, :retention, %{}) |> Map.new()
    memory_bytes = Map.get(retention, :memory_bytes, 1_048_576)
    journal = EventLog.open(id, retention)

    context = %{
      run_id: id,
      provider: provider,
      config: config,
      telemetry_context: %{run_id: id, provider: provider},
      process_manager: Jido.Harness.ProcessManager,
      run_owner: self()
    }

    state = %{
      id: id,
      provider: provider,
      request: request,
      adapter: adapter,
      context: context,
      status: :starting,
      started_at: timestamp(),
      finished_at: nil,
      provider_session_id: request.provider_session_id,
      sequence: 0,
      buffer: EventLog.new_buffer(memory_bytes),
      journal: journal,
      task: nil,
      adapter_started_at: nil,
      runtime_timer: nil,
      runtime_token: nil,
      idle_timer: nil,
      idle_token: nil,
      terminal_event: nil,
      text_tail: TextTail.new(memory_bytes),
      final_text_tail: nil,
      usage: %{},
      error: nil,
      result: nil
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    started = Event.new!(%{type: :run_started, provider: state.provider, payload: %{"cwd" => state.request.cwd}})
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
        invoke_adapter(state.adapter, state.request, state.context, owner)
      end)

    {:noreply, state |> Map.put(:task, task) |> schedule_runtime() |> schedule_idle()}
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, {:ok, info(state)}, state}

  def handle_call(:result, _from, %{result: %RunResult{} = result} = state), do: {:reply, {:ok, result}, state}
  def handle_call(:result, _from, state), do: {:reply, {:pending, info(state)}, state}

  def handle_call({:replay, cursor, limit}, _from, state) do
    {records, state} = replay_records(state, cursor, limit)
    {:reply, {:ok, Enum.map(records, &record_to_event(state, &1))}, state}
  end

  def handle_call(:cancel, _from, %{result: %RunResult{}} = state), do: {:reply, :ok, state}

  def handle_call(:cancel, _from, %{terminal_event: %Event{}} = state) do
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
    EventLog.remove(state.journal)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:prune, _from, state), do: {:reply, {:error, :running}, state}

  @impl true
  def handle_info({:adapter_event, %Event{} = event}, %{terminal_event: nil} = state) do
    state = schedule_idle(state)

    state =
      if event.provider_session_id,
        do: %{state | provider_session_id: event.provider_session_id},
        else: state

    if event.type == :run_started do
      {:noreply, state}
    else
      state = append(state, event)
      state = if Event.terminal?(event), do: %{state | terminal_event: event}, else: state
      {:noreply, state}
    end
  end

  def handle_info({:adapter_event, _event}, state), do: {:noreply, state}

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

  def handle_info({:run_timeout, :runtime, token}, %{runtime_token: token, status: status} = state)
      when status in [:starting, :running] do
    {:noreply, timeout(state, :runtime)}
  end

  def handle_info({:run_timeout, :idle, token}, %{idle_token: token, status: status} = state)
      when status in [:starting, :running] do
    {:noreply, timeout(state, :idle)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    :ok
  end

  defp invoke_adapter(adapter, request, context, owner) do
    try do
      case adapter.run(request, context) do
        {:ok, stream} ->
          if Enumerable.impl_for(stream) do
            Enum.each(stream, fn
              %Event{} = event -> send(owner, {:adapter_event, event})
              other -> throw({:invalid_adapter_event, other})
            end)

            :ok
          else
            {:error, Error.execution("adapter run/2 did not return an enumerable", provider: context.provider)}
          end

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error,
           Error.execution("adapter returned an invalid result",
             provider: context.provider,
             details: %{value: inspect(other)}
           )}
      end
    rescue
      exception ->
        {:error,
         Error.execution("adapter execution raised",
           provider: context.provider,
           cause: exception,
           details: %{message: Exception.message(exception)}
         )}
    catch
      kind, reason ->
        {:error, Error.execution("adapter execution terminated", provider: context.provider, cause: {kind, reason})}
    end
  end

  defp append(state, %Event{} = event) do
    event = Event.attach(event, state.id, state.provider, state.sequence + 1)
    secrets = Jido.Harness.Redaction.secrets_from_env(state.request.env)
    {buffer, journal} = EventLog.append(state.buffer, state.journal, event, secrets)

    :telemetry.execute([:jido, :harness, :run, :event], %{count: 1}, %{
      run_id: state.id,
      provider: state.provider,
      type: event.type
    })

    state
    |> Map.put(:sequence, event.sequence)
    |> Map.put(:buffer, buffer)
    |> Map.put(:journal, journal)
    |> accumulate(event)
  end

  defp append_terminal(%{terminal_event: %Event{}} = state, _type, _payload), do: state

  defp append_terminal(state, type, payload) do
    event =
      Event.new!(%{
        type: type,
        provider: state.provider,
        provider_session_id: state.provider_session_id,
        payload: payload
      })

    state = append(state, event)
    %{state | terminal_event: event}
  end

  defp accumulate(state, %Event{type: :output_text_delta, payload: payload}) do
    case Map.get(payload, "text") do
      text when is_binary(text) -> %{state | text_tail: TextTail.append(state.text_tail, text)}
      _ -> state
    end
  end

  defp accumulate(state, %Event{type: :output_text_final, payload: payload}) do
    case Map.get(payload, "text") do
      text when is_binary(text) -> %{state | final_text_tail: TextTail.replace(state.text_tail, text)}
      _ -> state
    end
  end

  defp accumulate(state, %Event{type: :usage, payload: payload}), do: %{state | usage: Map.merge(state.usage, payload)}
  defp accumulate(state, _event), do: state

  defp finish_success(%{terminal_event: nil} = state) do
    state |> append_terminal(:run_completed, %{}) |> finalize(:completed, nil)
  end

  defp finish_success(%{terminal_event: %{type: :run_completed}} = state), do: finalize(state, :completed, nil)
  defp finish_success(%{terminal_event: %{type: :run_cancelled}} = state), do: finalize(state, :cancelled, nil)
  defp finish_success(%{terminal_event: %{type: :run_failed}} = state), do: finalize_from_terminal(state)

  defp finish_error(%{terminal_event: nil} = state, reason) do
    error = normalize_error(state, reason)
    state |> append_terminal(:run_failed, %{"error" => Exception.message(error)}) |> finalize(:failed, error)
  end

  defp finish_error(%{terminal_event: %Event{}} = state, _reason), do: finalize_from_terminal(state)

  defp finalize(state, status, error) do
    events = Buffer.events(state.buffer)
    text = state.final_text_tail || state.text_tail

    result = %RunResult{
      run_id: state.id,
      provider: state.provider,
      provider_session_id: state.provider_session_id,
      status: status,
      text: text.data,
      text_truncated?: text.truncated?,
      usage: state.usage,
      events: events,
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

    %{
      state
      | status: status,
        error: error,
        finished_at: timestamp(),
        result: result,
        adapter_started_at: nil,
        runtime_timer: nil,
        idle_timer: nil
    }
  end

  defp normalize_error(state, %Error{} = error) do
    %{error | provider: error.provider || state.provider, run_id: error.run_id || state.id}
  end

  defp normalize_error(state, reason),
    do: Error.execution("provider run failed", provider: state.provider, run_id: state.id, cause: reason)

  defp maybe_native_cancel(state) do
    if function_exported?(state.adapter, :cancel, 2) do
      _ = state.adapter.cancel(state.id, state.context)
    end
  rescue
    _ -> :ok
  end

  defp stop_adapter(state) do
    maybe_native_cancel(state)
    if state.task, do: Task.shutdown(state.task, 5_000)
    %{state | task: nil}
  end

  defp timeout(%{terminal_event: %Event{}} = state, _kind) do
    state |> stop_adapter() |> finalize_from_terminal()
  end

  defp timeout(state, kind) do
    error = Error.new(:timeout, "#{kind} timeout exceeded", provider: state.provider, run_id: state.id)

    state
    |> stop_adapter()
    |> append_terminal(:run_failed, %{"error" => error.message, "timeout" => Atom.to_string(kind)})
    |> finalize(:failed, error)
  end

  defp finalize_from_terminal(%{terminal_event: %Event{type: :run_completed}} = state),
    do: finalize(state, :completed, nil)

  defp finalize_from_terminal(%{terminal_event: %Event{type: :run_cancelled}} = state),
    do: finalize(state, :cancelled, nil)

  defp finalize_from_terminal(%{terminal_event: %Event{type: :run_failed, payload: payload}} = state) do
    message =
      case Map.get(payload, "error") do
        value when is_binary(value) and value != "" -> value
        _value -> "provider reported failure"
      end

    error = state.error || Error.execution(message, provider: state.provider, run_id: state.id)
    finalize(state, :failed, error)
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
    {records, journal, available_from} = EventLog.replay(state.buffer, state.journal, cursor, limit)
    {prepend_gap(records, state, cursor, available_from), %{state | journal: journal}}
  end

  defp prepend_gap(records, _state, cursor, available_from) when cursor >= available_from - 1, do: records

  defp prepend_gap(records, state, _cursor, available_from) do
    gap =
      Event.new!(%{
        type: :provider_event,
        run_id: state.id,
        provider: state.provider,
        provider_session_id: state.provider_session_id,
        sequence: max(1, available_from - 1),
        payload: %{"kind" => "replay_gap", "available_from" => available_from}
      })

    [gap | records]
  end

  defp record_to_event(_state, %Event{} = event), do: event

  defp record_to_event(state, record) do
    Event.new!(%{
      type: existing_atom(record["type"]),
      run_id: record["run_id"] || state.id,
      provider: existing_atom(record["provider"] || Atom.to_string(state.provider)),
      provider_session_id: record["provider_session_id"],
      turn_id: record["turn_id"],
      request_id: record["request_id"],
      sequence: record["sequence"],
      timestamp: record["timestamp"],
      payload: record["payload"] || %{},
      raw: nil
    })
  end

  defp existing_atom(value) when is_atom(value), do: value
  defp existing_atom(value) when is_binary(value), do: String.to_existing_atom(value)

  defp info(state) do
    %RunInfo{
      run_id: state.id,
      provider: state.provider,
      state: state.status,
      started_at: state.started_at,
      finished_at: state.finished_at,
      provider_session_id: state.provider_session_id,
      error: state.error,
      journal_dir: EventLog.dir(state.journal),
      output_cursor: state.sequence,
      metadata: state.request.metadata
    }
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
