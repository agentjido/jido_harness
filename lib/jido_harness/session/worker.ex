defmodule Jido.Harness.SessionWorker do
  @moduledoc false
  use GenServer, restart: :temporary

  alias Jido.Harness.{
    ApprovalResponse,
    Error,
    Event,
    EventLog,
    ID,
    InteractionCapabilities,
    SessionInfo,
    TurnRequest,
    Waiters
  }

  alias Jido.Harness.Session.{EventStore, Lifecycle, RequestValidator, State, Timers}

  import EventStore, only: [append: 2, append_queue_changed: 1]

  def start_link({id, provider, request, adapter, session_adapter, transport_spec, config}) do
    GenServer.start_link(
      __MODULE__,
      {id, provider, request, adapter, session_adapter, transport_spec, config},
      name: {:via, Registry, {Jido.Harness.SessionRegistry, id}}
    )
  end

  @impl true
  def init({id, provider, request, adapter, session_adapter, transport_spec, config}) do
    Process.flag(:trap_exit, true)
    retention = Map.merge(Map.get(config, :retention, %{}) |> Map.new(), request.retention)
    memory_bytes = Map.get(retention, :memory_bytes, 1_048_576)

    context = %{
      session_id: id,
      provider: provider,
      owner: self(),
      adapter: adapter,
      config: config,
      process_manager: Jido.Harness.ProcessManager,
      telemetry_context: %{session_id: id, provider: provider, transport: transport_spec.name}
    }

    state = %State{
      id: id,
      provider: provider,
      request: request,
      adapter: adapter,
      session_adapter: session_adapter,
      transport_spec: transport_spec,
      context: context,
      started_at: timestamp(),
      provider_session_id: request.provider_session_id,
      buffer: EventLog.new_buffer(memory_bytes),
      journal: EventLog.open(id, retention)
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    state =
      append(
        state,
        Event.new!(type: :session_started, provider: state.provider, payload: %{"cwd" => state.request.cwd})
      )

    :telemetry.execute([:jido, :harness, :session, :start], %{system_time: System.system_time()}, %{
      session_id: state.id,
      provider: state.provider,
      transport: state.transport_spec.name
    })

    case state.session_adapter.open(state.request, state.context) do
      {:ok, handle} ->
        monitor = if is_pid(handle), do: Process.monitor(handle), else: nil

        state =
          state
          |> Map.put(:handle, handle)
          |> Map.put(:handle_monitor, monitor)
          |> Map.put(:status, :idle)
          |> append(Event.new!(type: :session_ready, provider: state.provider, payload: transport_payload(state)))
          |> append(Event.new!(type: :session_idle, provider: state.provider, payload: %{}))
          |> Timers.schedule_session_idle()

        {:noreply, state}

      {:error, reason} ->
        {:noreply, Lifecycle.fail_session(state, reason)}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, {:ok, EventStore.info(state)}, state}

  def handle_call({:replay, cursor, limit}, _from, state) do
    {events, state} = EventStore.replay(state, cursor, limit)
    {:reply, {:ok, events}, state}
  end

  def handle_call({:turn_result, turn_id}, _from, state) do
    case Map.fetch(state.results, turn_id) do
      {:ok, result} ->
        {:reply, {:ok, result}, state}

      :error ->
        if MapSet.member?(state.known_turns, turn_id) do
          {:reply, {:pending, EventStore.info(state)}, state}
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
         :ok <- RequestValidator.validate_turn_request(state, request) do
      turn_id = ID.generate("turn")
      queue = :queue.in({turn_id, request}, state.queue)

      state =
        %{state | queue: queue, known_turns: MapSet.put(state.known_turns, turn_id)}
        |> append(Event.new!(type: :turn_queued, provider: state.provider, turn_id: turn_id, payload: %{}))
        |> append_queue_changed()

      if state.status == :idle, do: send(self(), :start_next)
      {:reply, {:ok, turn_id}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:follow_up, _input}, _from, state), do: {:reply, {:error, :closed}, state}

  def handle_call({:steer, input}, _from, %{active: active} = state) when not is_nil(active) do
    capabilities = state.transport_spec.capabilities

    with true <- InteractionCapabilities.supported?(capabilities, :steer),
         true <- function_exported?(state.session_adapter, :steer, 3),
         {:ok, request} <- TurnRequest.new(input),
         :ok <- RequestValidator.validate_turn_request(state, request),
         :ok <- RequestValidator.validate_steer_request(state, request),
         request_id = ID.generate("request"),
         :ok <- state.session_adapter.steer(state.handle, request, request_id) do
      event =
        Event.new!(
          type: :input_accepted,
          provider: state.provider,
          turn_id: active.id,
          request_id: request_id,
          payload: %{"kind" => "steer"}
        )

      {:reply, {:ok, request_id}, append(state, event)}
    else
      false -> {:reply, {:error, RequestValidator.unsupported(state, :steer)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:steer, _input}, _from, state), do: {:reply, {:error, :no_active_turn}, state}

  def handle_call({:interrupt, turn_id}, _from, %{active: active} = state) when not is_nil(active) do
    if turn_id in [:active, active.id] do
      case state.session_adapter.interrupt(state.handle, active.id) do
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
         true <- InteractionCapabilities.supported?(state.transport_spec.capabilities, :approvals),
         true <- function_exported?(state.session_adapter, :respond_approval, 3),
         {:ok, response} <- ApprovalResponse.new(response),
         :ok <- state.session_adapter.respond_approval(state.handle, request_id, response) do
      Timers.cancel(approval.timer)

      event =
        Event.new!(
          type: :approval_resolved,
          provider: state.provider,
          turn_id: state.active && state.active.id,
          request_id: request_id,
          payload: %{"decision" => Atom.to_string(response.decision), "scope" => Atom.to_string(response.scope)}
        )

      state = %{state | pending_approvals: Map.delete(state.pending_approvals, request_id)} |> append(event)
      status = if map_size(state.pending_approvals) == 0, do: :running, else: :awaiting_approval
      {:reply, :ok, %{state | status: status}}
    else
      :error -> {:reply, {:error, :not_found}, state}
      false -> {:reply, {:error, RequestValidator.unsupported(state, :approvals)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:configure, changes}, _from, state) when is_map(changes) do
    capabilities = state.transport_spec.capabilities

    with {:ok, changes} <- RequestValidator.normalize_configuration(changes),
         {:ok, request} <- RequestValidator.validate_configuration(state, changes),
         true <- RequestValidator.configuration_supported?(capabilities, changes),
         true <- function_exported?(state.session_adapter, :configure, 2),
         :ok <- state.session_adapter.configure(state.handle, changes) do
      {:reply, :ok, %{state | request: request}}
    else
      false -> {:reply, {:error, RequestValidator.unsupported(state, :dynamic_configuration)}, state}
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
    EventLog.remove(state.journal)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:prune, _from, state), do: {:reply, {:error, :running}, state}

  @impl true
  def handle_cast({:cancel_await, request_ref}, state),
    do: {:noreply, %{state | waiters: Waiters.cancel(state.waiters, request_ref)}}

  @impl true
  def handle_info({:session_adapter_event, %Event{} = event}, state) do
    cond do
      SessionInfo.terminal?(EventStore.info(state)) ->
        {:noreply, state}

      Event.run_terminal?(event) or event.type == :run_started ->
        {:noreply, state}

      Event.session_terminal?(event) ->
        {:noreply, Lifecycle.terminate_session(state, event.type, event.payload)}

      true ->
        event = EventStore.normalize_adapter_event(event, state)
        state = if event.provider_session_id, do: %{state | provider_session_id: event.provider_session_id}, else: state

        if event.type == :approval_requested do
          {:noreply, Lifecycle.handle_approval_request(state, event)}
        else
          handle_turn_event(state, event)
        end
    end
  end

  def handle_info(:start_next, %{status: :idle, active: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {turn_id, request}}, queue} ->
        state = %{state | queue: queue} |> append_queue_changed()

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

      case state.session_adapter.interrupt(state.handle, state.active.id) do
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

        _ = state.session_adapter.respond_approval(state.handle, request_id, response)

        event =
          Event.new!(
            type: :approval_resolved,
            provider: state.provider,
            turn_id: state.active && state.active.id,
            request_id: request_id,
            payload: %{"decision" => "deny", "scope" => "once", "reason" => "timeout"}
          )

        status = if map_size(approvals) == 0, do: :running, else: :awaiting_approval
        {:noreply, %{append(state, event) | pending_approvals: approvals, status: status}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{handle_monitor: ref} = state) do
    if state.status in [:closed, :failed, :cancelled] do
      {:noreply, state}
    else
      {:noreply, Lifecycle.fail_session(%{state | handle: nil, handle_monitor: nil}, {:transport_exit, reason})}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, %{state | waiters: Waiters.drop_monitor(state.waiters, monitor)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_turn_event(state, event) do
    if stale_turn_event?(state, event) do
      {:noreply, state}
    else
      state = Timers.schedule_turn_idle(state)

      cond do
        event.type == :turn_started ->
          {:noreply, state}

        (Event.turn_terminal?(event) and state.active) && event.turn_id == state.active.id ->
          {:noreply, Lifecycle.finish_turn(state, event.type, event.payload, nil, event)}

        true ->
          {:noreply, append(state, event)}
      end
    end
  end

  @impl true
  def terminate(_reason, state) do
    Timers.cancel_all(state)

    if state.handle do
      _ = state.session_adapter.close(state.handle)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp stale_turn_event?(state, %Event{turn_id: turn_id}) when is_binary(turn_id),
    do: Map.has_key?(state.results, turn_id)

  defp stale_turn_event?(_state, _event), do: false

  defp transport_payload(state) do
    %{
      "transport" => Atom.to_string(state.transport_spec.name),
      "maturity" => Atom.to_string(state.transport_spec.capabilities.maturity),
      "process" => Atom.to_string(state.transport_spec.capabilities.process)
    }
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
