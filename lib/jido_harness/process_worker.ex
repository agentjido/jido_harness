defmodule Jido.Harness.ProcessWorker do
  @moduledoc false
  use GenServer, restart: :temporary

  alias Jido.Harness.{Buffer, Journal, ProcessEvent, ProcessInfo, Redaction}

  @default_grace_ms 5_000
  @terminal_statuses [:exited, :failed, :cancelled, :timed_out]

  def start_link({id, spec}) do
    GenServer.start_link(__MODULE__, {id, spec}, name: {:via, Registry, {Jido.Harness.ProcessRegistry, id}})
  end

  @impl true
  def init({id, spec}) do
    Process.flag(:trap_exit, true)
    now = timestamp()
    memory_bytes = Map.get(spec.retention, :memory_bytes, 1_048_576)
    manager_config = Application.get_env(:jido_harness, :process_manager, %{}) |> Map.new()
    journal = open_journal(id, spec.retention)

    state = %{
      id: id,
      spec: spec,
      driver: Application.get_env(:jido_harness, :process_driver, Jido.Harness.ProcessDriver.Erlexec),
      exec_pid: nil,
      os_pid: nil,
      status: :starting,
      started_at: now,
      finished_at: nil,
      exit_status: nil,
      error: nil,
      sequence: 0,
      buffer: Buffer.new(memory_bytes),
      journal: journal,
      runtime_timer: nil,
      runtime_token: nil,
      idle_timer: nil,
      idle_token: nil,
      stop_reason: nil,
      escalation_timer: nil,
      cancel_grace_ms: Map.get(manager_config, :cancel_grace_ms, @default_grace_ms),
      term_grace_ms: Map.get(manager_config, :term_grace_ms, @default_grace_ms)
    }

    state = Map.put(state, :owner_monitor, monitor_owner(spec.lifecycle_owner))

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    case state.driver.start(state.spec, self()) do
      {:ok, exec_pid, os_pid} ->
        state = %{state | exec_pid: exec_pid, os_pid: os_pid, status: :running}
        state = append(state, :started, nil, %{"os_pid" => os_pid})
        state = schedule_runtime(state) |> schedule_idle()
        {:noreply, state}

      {:error, reason} ->
        state = %{state | status: :failed, error: reason, finished_at: timestamp()}
        {:noreply, append(state, :failed, nil, %{"error" => inspect(reason)})}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, {:ok, info(state)}, state}

  def handle_call({:replay, cursor, limit}, _from, state) do
    {records, state} = replay_records(state, cursor, limit)
    events = Enum.map(records, &record_to_event(state.id, &1))
    {:reply, {:ok, events}, state}
  end

  def handle_call({:input, data}, _from, %{status: :running} = state) do
    data = if data == :eof and state.spec.pty != false, do: <<4>>, else: data
    {:reply, state.driver.send_input(state.exec_pid || state.os_pid, data), state}
  end

  def handle_call({:input, _data}, _from, state), do: {:reply, {:error, :not_running}, state}

  def handle_call(:cancel, _from, state) when state.status in [:starting, :running, :stopping] do
    {:reply, :ok, begin_stop(state, :cancelled)}
  end

  def handle_call(:cancel, _from, state), do: {:reply, :ok, state}

  def handle_call(:kill, _from, state) when state.status in [:starting, :running, :stopping] do
    _ = signal(state, :sigkill)
    {:reply, :ok, %{state | status: :stopping, stop_reason: state.stop_reason || :cancelled}}
  end

  def handle_call(:kill, _from, state), do: {:reply, :ok, state}

  def handle_call(:prune, _from, state) when state.status in [:exited, :failed, :cancelled, :timed_out] do
    if state.journal, do: Journal.remove(state.journal)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:prune, _from, state), do: {:reply, {:error, :running}, state}

  @impl true
  def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid, status: status} = state)
      when status not in @terminal_statuses do
    {:noreply, state |> append(:stdout, :stdout, data) |> schedule_idle()}
  end

  def handle_info({:stderr, os_pid, data}, %{os_pid: os_pid, status: status} = state)
      when status not in @terminal_statuses do
    {:noreply, state |> append(:stderr, :stderr, data) |> schedule_idle()}
  end

  def handle_info({:DOWN, _monitor, :process, exec_pid, reason}, %{exec_pid: exec_pid} = state) do
    {:noreply, finish(state, reason)}
  end

  def handle_info({:EXIT, exec_pid, reason}, %{exec_pid: exec_pid} = state) do
    {:noreply, finish(state, reason)}
  end

  def handle_info({:runtime_timeout, token}, %{runtime_token: token} = state) do
    {:noreply, begin_stop(state, :timed_out)}
  end

  def handle_info({:idle_timeout, token}, %{idle_token: token} = state) do
    {:noreply, begin_stop(state, :timed_out)}
  end

  def handle_info({:DOWN, monitor, :process, _owner, _reason}, %{owner_monitor: monitor} = state) do
    {:noreply, begin_stop(state, :cancelled)}
  end

  def handle_info({:escalate, :sigterm}, %{status: :stopping} = state) do
    _ = signal(state, :sigterm)
    timer = Process.send_after(self(), {:escalate, :sigkill}, state.term_grace_ms)
    {:noreply, %{state | escalation_timer: timer}}
  end

  def handle_info({:escalate, :sigkill}, %{status: :stopping} = state) do
    _ = signal(state, :sigkill)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.status in [:starting, :running, :stopping], do: signal(state, :sigkill)
    :ok
  end

  defp append(state, type, stream, data) do
    sequence = state.sequence + 1

    event = %ProcessEvent{
      process_id: state.id,
      sequence: sequence,
      timestamp: timestamp(),
      type: type,
      stream: stream,
      data: data,
      metadata: %{}
    }

    journal = append_journal(state.journal, event, Redaction.secrets_from_env(state.spec.env))
    :telemetry.execute([:jido, :harness, :process, type], %{count: 1}, %{process_id: state.id})
    %{state | sequence: sequence, buffer: Buffer.append(state.buffer, event), journal: journal}
  end

  defp append_journal(nil, _event, _secrets), do: nil

  defp append_journal(journal, event, secrets) do
    case Journal.append(journal, event |> Map.from_struct() |> Redaction.redact(secrets)) do
      {:ok, updated} -> updated
      {:error, _reason, updated} -> updated
    end
  end

  defp replay_records(%{journal: %Journal{failed?: false} = journal} = state, cursor, limit) do
    {records, journal} = Journal.replay(journal, cursor, limit)
    {prepend_gap(records, state.id, cursor, journal.available_from), %{state | journal: journal}}
  end

  defp replay_records(state, cursor, limit) do
    records =
      state.buffer
      |> Buffer.events()
      |> Enum.filter(&(&1.sequence > cursor))
      |> Enum.take(limit)
      |> Enum.map(&Map.from_struct/1)

    available_from =
      case records do
        [%{sequence: sequence} | _] -> sequence
        _ -> cursor + 1
      end

    {prepend_gap(records, state.id, cursor, available_from), state}
  end

  defp prepend_gap(records, _id, cursor, available_from) when cursor >= available_from - 1, do: records

  defp prepend_gap(records, id, _cursor, available_from) do
    gap = %{
      "process_id" => id,
      "sequence" => max(1, available_from - 1),
      "timestamp" => timestamp(),
      "type" => "replay_gap",
      "stream" => nil,
      "data" => %{"available_from" => available_from},
      "metadata" => %{}
    }

    [gap | records]
  end

  defp record_to_event(_id, %ProcessEvent{} = event), do: event
  defp record_to_event(_id, record) when is_map_key(record, "process_id"), do: ProcessEvent.from_record(record)

  defp record_to_event(id, record),
    do: record |> stringify_record_keys() |> Map.put_new("process_id", id) |> ProcessEvent.from_record()

  defp stringify_record_keys(record), do: Map.new(record, fn {key, value} -> {to_string(key), value} end)

  defp begin_stop(state, reason) when state.status in [:starting, :running, :stopping] do
    _ = signal(state, :sigint)
    cancel_timer(state.runtime_timer)
    cancel_timer(state.idle_timer)
    cancel_timer(state.escalation_timer)
    timer = Process.send_after(self(), {:escalate, :sigterm}, state.cancel_grace_ms)
    %{state | status: :stopping, stop_reason: state.stop_reason || reason, escalation_timer: timer}
  end

  defp begin_stop(state, _reason), do: state

  defp finish(%{status: status} = state, _reason) when status in @terminal_statuses, do: state

  defp finish(state, reason) do
    cancel_timer(state.runtime_timer)
    cancel_timer(state.idle_timer)
    cancel_timer(state.escalation_timer)
    exit_status = exit_status(reason)

    {status, event_type} =
      case state.stop_reason do
        :cancelled -> {:cancelled, :cancelled}
        :timed_out -> {:timed_out, :timed_out}
        nil when exit_status == 0 -> {:exited, :exited}
        nil -> {:failed, :failed}
      end

    state = %{
      state
      | status: status,
        exit_status: exit_status,
        finished_at: timestamp(),
        error: error_reason(status, exit_status, reason)
    }

    append(state, event_type, nil, %{"exit_status" => exit_status, "reason" => inspect(reason)})
  end

  defp schedule_runtime(%{spec: %{runtime_timeout_ms: :infinity}} = state), do: state

  defp schedule_runtime(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:runtime_timeout, token}, state.spec.runtime_timeout_ms)
    %{state | runtime_timer: timer, runtime_token: token}
  end

  defp schedule_idle(%{spec: %{idle_timeout_ms: :infinity}} = state), do: state

  defp schedule_idle(state) do
    cancel_timer(state.idle_timer)
    token = make_ref()
    timer = Process.send_after(self(), {:idle_timeout, token}, state.spec.idle_timeout_ms)
    %{state | idle_timer: timer, idle_token: token}
  end

  defp signal(%{exec_pid: nil, os_pid: nil}, _signal), do: :ok
  defp signal(state, signal), do: state.driver.signal(state.os_pid || state.exec_pid, signal)
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: true, info: false)

  defp info(state) do
    %ProcessInfo{
      process_id: state.id,
      state: state.status,
      started_at: state.started_at,
      finished_at: state.finished_at,
      os_pid: state.os_pid,
      exit_status: state.exit_status,
      error: state.error,
      journal_dir: if(state.journal, do: state.journal.dir),
      output_cursor: state.sequence,
      metadata: state.spec.metadata
    }
  end

  defp exit_status(:normal), do: 0
  defp exit_status({:exit_status, status}) when is_integer(status), do: decode_wait_status(status)
  defp exit_status(status) when is_integer(status), do: decode_wait_status(status)
  defp exit_status(_reason), do: nil
  defp error_reason(:failed, exit_status, _reason), do: {:exit_status, exit_status}
  defp error_reason(_status, _exit_status, _reason), do: nil

  defp decode_wait_status(status) do
    case :exec.status(status) do
      {:status, exit_status} -> exit_status
      {:signal, signal, _core?} -> 128 + :exec.signal_to_int(signal)
    end
  rescue
    _error -> status
  end

  defp open_journal(id, retention) do
    case Journal.open(id, retention) do
      {:ok, journal} ->
        journal

      {:error, reason} ->
        :telemetry.execute([:jido, :harness, :journal, :error], %{count: 1}, %{owner_id: id, reason: reason})
        nil
    end
  end

  defp monitor_owner(owner) when is_pid(owner), do: Process.monitor(owner)
  defp monitor_owner(_owner), do: nil

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
