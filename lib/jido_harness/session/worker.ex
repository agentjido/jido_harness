defmodule Jido.Harness.SessionWorker do
  @moduledoc false
  use GenServer, restart: :temporary

  alias Jido.Harness.{
    ApprovalResponse,
    Error,
    SignalLog,
    ID,
    SessionInfo,
    TurnRequest,
    Waiters
  }

  alias Jido.Harness.Adapter.Message
  alias Jido.Harness.Session.{Lifecycle, RequestValidator, SignalStore, State, Timers}
  alias Jido.Harness.SessionAdapters.ACP

  import SignalStore, only: [append: 2, append_queue_changed: 1]

  def start_link({id, provider, request, adapter, acp_agent, config}) do
    GenServer.start_link(
      __MODULE__,
      {id, provider, request, adapter, acp_agent, config},
      name: {:via, Registry, {Jido.Harness.SessionRegistry, id}}
    )
  end

  @impl true
  def init({id, provider, request, adapter, acp_agent, config}) do
    Process.flag(:trap_exit, true)
    retention = Map.merge(Map.get(config, :retention, %{}) |> Map.new(), request.retention)
    memory_bytes = Map.get(retention, :memory_bytes, 1_048_576)

    context = %{
      session_id: id,
      provider: provider,
      owner: self(),
      adapter: adapter,
      acp_agent: acp_agent,
      config: config,
      process_manager: Jido.Harness.ProcessManager,
      telemetry_context: %{session_id: id, provider: provider, protocol: :acp}
    }

    state = %State{
      id: id,
      provider: provider,
      request: request,
      secrets: Jido.Harness.Redaction.prepare(Jido.Harness.Redaction.secrets_from_env(request.env)),
      adapter: adapter,
      acp_agent: acp_agent,
      context: context,
      started_at: timestamp(),
      provider_session_id: request.provider_session_id,
      buffer: SignalLog.new_buffer(memory_bytes),
      signal_log: SignalLog.open(:session, id, retention)
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    state =
      append(
        state,
        Message.new!(type: :session_started, payload: %{"cwd" => state.request.cwd})
      )

    :telemetry.execute([:jido, :harness, :session, :start], %{system_time: System.system_time()}, %{
      session_id: state.id,
      provider: state.provider,
      protocol: :acp
    })

    case ACP.open(state.request, state.context) do
      {:ok, handle} ->
        monitor = Process.monitor(handle)

        state =
          state
          |> Map.put(:handle, handle)
          |> Map.put(:handle_monitor, monitor)
          |> Map.put(:status, :idle)
          |> append(Message.new!(type: :session_ready, payload: transport_payload(state)))
          |> append(Message.new!(type: :session_idle, payload: %{}))
          |> Timers.schedule_session_idle()

        {:noreply, state}

      {:error, reason} ->
        {:noreply, Lifecycle.fail_session(state, reason)}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, {:ok, SignalStore.info(state)}, state}

  def handle_call({:replay, cursor, limit}, _from, state) do
    {signals, state} = SignalStore.replay(state, cursor, limit)
    {:reply, {:ok, signals}, state}
  end

  def handle_call({:replay_page, cursor, limits}, _from, state) do
    {page, signal_log} =
      SignalLog.replay(
        state.signal_log,
        cursor,
        limits.max_signals,
        limits.max_bytes,
        &SignalStore.record_to_signal(state, &1)
      )

    {:reply, {:ok, page}, %{state | signal_log: signal_log}}
  end

  def handle_call({:turn_result, turn_id}, _from, state) do
    case Map.fetch(state.results, turn_id) do
      {:ok, result} ->
        {:reply, {:ok, result}, state}

      :error ->
        if MapSet.member?(state.known_turns, turn_id) do
          {:reply, {:pending, SignalStore.info(state)}, state}
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  def handle_call({:await_turn, _request_ref, turn_id}, _from, state) when is_map_key(state.results, turn_id),
    do: {:reply, {:ok, Map.fetch!(state.results, turn_id)}, state}

  def handle_call({:await_turn, request_ref, turn_id}, from, state) do
    if MapSet.member?(state.known_turns, turn_id) do
      waiters = Waiters.add(state.waiters, request_ref, from, turn_id)
      {:noreply, %{state | waiters: waiters}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:send_message, input}, _from, %{status: :idle, active: nil} = state) do
    with {:ok, request} <- TurnRequest.new(input),
         :ok <- RequestValidator.validate_turn_request(state, request),
         {:ok, turn_id, state} <- Lifecycle.start_turn(state, request, ID.generate("turn")) do
      {:reply, {:ok, turn_id}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_message, _input}, _from, %{status: status} = state)
      when status in [:starting, :running, :awaiting_approval, :closing],
      do: {:reply, {:error, :busy}, state}

  def handle_call({:send_message, _input}, _from, state), do: {:reply, {:error, :closed}, state}

  def handle_call({:follow_up, input}, _from, state) when state.status in [:idle, :running, :awaiting_approval] do
    with {:ok, request} <- TurnRequest.new(input),
         :ok <- RequestValidator.validate_turn_request(state, request),
         :ok <- validate_queue_capacity(state, request) do
      turn_id = ID.generate("turn")
      queue = :queue.in({turn_id, request}, state.queue)

      state =
        %{
          state
          | queue: queue,
            queued_bytes: state.queued_bytes + :erlang.external_size(request),
            known_turns: MapSet.put(state.known_turns, turn_id)
        }
        |> append(Message.new!(type: :turn_queued, turn_id: turn_id, payload: %{}))
        |> append_queue_changed()

      if state.status == :idle, do: send(self(), :start_next)
      {:reply, {:ok, turn_id}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:follow_up, _input}, _from, state), do: {:reply, {:error, :closed}, state}

  def handle_call({:steer, input}, from, %{active: active} = state) when not is_nil(active) do
    with {:ok, request} <- TurnRequest.new(input),
         :ok <- RequestValidator.validate_turn_request(state, request),
         :ok <- RequestValidator.validate_steer_request(state, request) do
      handle = state.handle
      unsupported = RequestValidator.unsupported(state, :steer)

      # The agent answers once the input is in the turn. Meanwhile this
      # process goes on answering approvals and recording the turn's Signals.
      {:ok, _pid} =
        Task.Supervisor.start_child(Jido.Harness.SessionTaskSupervisor, fn ->
          GenServer.reply(from, steer_reply(ACP.steer(handle, request, active.id), active.id, unsupported))
        end)

      {:noreply, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:steer, _input}, _from, state), do: {:reply, {:error, :no_active_turn}, state}

  def handle_call({:interrupt, turn_id}, _from, %{active: active} = state) when not is_nil(active) do
    if turn_id in [:active, active.id] do
      case ACP.interrupt(state.handle, active.id) do
        :ok -> {:reply, :ok, Lifecycle.finish_turn(state, :turn_interrupted, %{"reason" => "interrupted"}, nil)}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_active}, state}
    end
  end

  def handle_call({:interrupt, _turn_id}, _from, state), do: {:reply, {:error, :no_active_turn}, state}

  def handle_call({:respond_approval, request_id, response}, _from, state) do
    with {:ok, approval} <- Map.fetch(state.pending_approvals, request_id),
         :ok <- RequestValidator.require_capability(state, :approvals),
         {:ok, response} <- ApprovalResponse.new(response),
         :ok <- ACP.respond_approval(state.handle, request_id, response) do
      Timers.cancel(approval.timer)

      message =
        Message.new!(
          type: :approval_resolved,
          turn_id: state.active && state.active.id,
          request_id: request_id,
          payload: %{"decision" => Atom.to_string(response.decision), "scope" => Atom.to_string(response.scope)}
        )

      state = %{state | pending_approvals: Map.delete(state.pending_approvals, request_id)} |> append(message)
      {:reply, :ok, after_approval(state)}
    else
      :error -> {:reply, {:error, :not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:configure, changes}, _from, state) when is_map(changes) do
    with {:ok, changes} <- RequestValidator.normalize_configuration(changes),
         {:ok, request} <- RequestValidator.validate_configuration(state, changes),
         :ok <- RequestValidator.require_configuration_capabilities(state, changes),
         :ok <- ACP.configure(state.handle, changes) do
      {:reply, :ok, %{state | request: request}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  rescue
    exception -> {:reply, {:error, Error.validation("invalid session configuration", cause: exception)}, state}
  end

  def handle_call({:configure, _changes}, _from, state),
    do: {:reply, {:error, Error.validation("session configuration must be a map")}, state}

  def handle_call(:close, _from, state) do
    state = Lifecycle.terminate_session(state, :session_closed, %{"reason" => "closed"})
    {:reply, :ok, state}
  end

  def handle_call(:kill, _from, state) do
    state = Lifecycle.terminate_session(state, :session_cancelled, %{"reason" => "killed"})
    {:reply, :ok, state}
  end

  def handle_call(:prune, _from, state) when state.status in [:closed, :failed, :cancelled] do
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
  def handle_info({:session_adapter_message, %Message{} = message}, state) do
    cond do
      SessionInfo.terminal?(SignalStore.info(state)) ->
        {:noreply, state}

      message.type in [:run_started, :run_completed, :run_failed, :run_cancelled] ->
        {:noreply, state}

      message.type in [:session_closed, :session_failed, :session_cancelled] ->
        {:noreply, Lifecycle.terminate_session(state, message.type, message.payload)}

      true ->
        message = SignalStore.normalize_adapter_message(message, state)

        state =
          if message.provider_session_id,
            do: %{state | provider_session_id: message.provider_session_id},
            else: state

        if message.type == :approval_requested do
          {:noreply, Lifecycle.handle_approval_request(state, message)}
        else
          handle_turn_message(state, message)
        end
    end
  end

  def handle_info(:start_next, %{status: :idle, active: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {turn_id, request}}, queue} ->
        state =
          %{state | queue: queue, queued_bytes: max(0, state.queued_bytes - :erlang.external_size(request))}
          |> append_queue_changed()

        case Lifecycle.start_turn(state, request, turn_id) do
          {:ok, _turn_id, state} -> {:noreply, state}
          {:error, reason} -> {:noreply, Lifecycle.fail_queued_turn(state, turn_id, request, reason)}
        end

      {:empty, _queue} ->
        {:noreply, state}
    end
  end

  def handle_info(:start_next, state), do: {:noreply, state}

  def handle_info({:session_timeout, :idle, token}, %{session_idle_token: token, status: :idle} = state) do
    {:noreply, Lifecycle.terminate_session(state, :session_closed, %{"reason" => "idle_timeout"})}
  end

  def handle_info({:session_timeout, kind, token}, state) when kind in [:runtime, :turn_idle] do
    expected = if kind == :runtime, do: state.turn_runtime_token, else: state.turn_idle_token

    if token == expected and state.active do
      error = Error.new(:timeout, "turn #{kind} timeout exceeded", provider: state.provider)

      case ACP.interrupt(state.handle, state.active.id) do
        :ok ->
          {:noreply,
           Lifecycle.finish_turn(
             state,
             :turn_failed,
             %{"error" => error.message, "timeout" => Atom.to_string(kind)},
             error
           )}

        {:error, reason} ->
          {:noreply, Lifecycle.fail_session(state, {:turn_timeout_interrupt_failed, kind, reason})}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:approval_timeout, request_id}, state) do
    case Map.pop(state.pending_approvals, request_id) do
      {nil, _approvals} ->
        {:noreply, state}

      {_approval, approvals} ->
        response = %ApprovalResponse{
          decision: :deny,
          scope: :once,
          reason: "approval timeout",
          provider_options: %{}
        }

        _ = ACP.respond_approval(state.handle, request_id, response)

        message =
          Message.new!(
            type: :approval_resolved,
            turn_id: state.active && state.active.id,
            request_id: request_id,
            payload: %{"decision" => "deny", "scope" => "once", "reason" => "timeout"}
          )

        {:noreply, after_approval(%{append(state, message) | pending_approvals: approvals})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{handle_monitor: ref} = state) do
    if state.status in [:closed, :failed, :cancelled] do
      {:noreply, state}
    else
      {:noreply, Lifecycle.fail_session(%{state | handle: nil, handle_monitor: nil}, {:acp_exit, reason})}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, %{state | waiters: Waiters.drop_monitor(state.waiters, monitor)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp after_approval(state) do
    cond do
      map_size(state.pending_approvals) > 0 ->
        %{state | status: :awaiting_approval}

      state.active ->
        %{state | status: :running}

      true ->
        send(self(), :start_next)
        Timers.schedule_session_idle(%{state | status: :idle})
    end
  end

  defp handle_turn_message(state, message) do
    if stale_turn_message?(state, message) do
      {:noreply, state}
    else
      state = Timers.schedule_turn_idle(state)

      cond do
        message.type == :turn_started ->
          {:noreply, state}

        (message.type in [:turn_completed, :turn_failed, :turn_interrupted] and state.active) &&
            message.turn_id == state.active.id ->
          {:noreply, Lifecycle.finish_turn(state, message.type, message.payload, nil, message)}

        true ->
          {:noreply, append(state, message)}
      end
    end
  end

  @impl true
  def terminate(_reason, state) do
    Timers.cancel_all(state)

    if state.handle do
      _ = ACP.close(state.handle)
    end

    SignalLog.close(state.signal_log)
  rescue
    _ -> :ok
  end

  defp stale_turn_message?(_state, %Message{turn_id: nil}), do: false
  defp stale_turn_message?(state, %Message{turn_id: turn_id}), do: is_nil(state.active) or state.active.id != turn_id

  defp validate_queue_capacity(state, request) do
    if :queue.len(state.queue) >= state.request.max_queued_turns or
         state.queued_bytes + :erlang.external_size(request) > state.request.max_queued_bytes,
       do: {:error, :queue_full},
       else: :ok
  end

  defp transport_payload(state) do
    %{
      "protocol" => "acp",
      "source" => Atom.to_string(state.acp_agent.source),
      "maturity" => Atom.to_string(state.acp_agent.maturity),
      "executable" => state.acp_agent.executable
    }
  end

  defp steer_reply(:ok, turn_id, _unsupported), do: {:ok, turn_id}
  defp steer_reply({:error, :unsupported}, _turn_id, unsupported), do: {:error, unsupported}
  defp steer_reply({:error, :not_active}, _turn_id, _unsupported), do: {:error, :no_active_turn}
  defp steer_reply({:error, reason}, _turn_id, _unsupported), do: {:error, reason}

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
