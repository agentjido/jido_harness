defmodule Jido.Harness.SessionWorker do
  @moduledoc false
  use GenServer, restart: :temporary

  alias Jido.Harness.{
    ApprovalResponse,
    Buffer,
    Error,
    Event,
    EventLog,
    ID,
    InteractionCapabilities,
    SessionInfo,
    SessionRequest,
    TextTail,
    TurnRequest,
    TurnResult
  }

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

    state = %{
      id: id,
      provider: provider,
      request: request,
      adapter: adapter,
      session_adapter: session_adapter,
      transport_spec: transport_spec,
      context: context,
      handle: nil,
      handle_monitor: nil,
      status: :starting,
      started_at: timestamp(),
      finished_at: nil,
      provider_session_id: request.provider_session_id,
      sequence: 0,
      buffer: EventLog.new_buffer(memory_bytes),
      journal: EventLog.open(id, retention),
      terminal_event: nil,
      active: nil,
      queue: :queue.new(),
      results: %{},
      known_turns: MapSet.new(),
      pending_approvals: %{},
      error: nil,
      session_idle_timer: nil,
      session_idle_token: nil,
      turn_runtime_timer: nil,
      turn_runtime_token: nil,
      turn_idle_timer: nil,
      turn_idle_token: nil
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
          |> schedule_session_idle()

        {:noreply, state}

      {:error, reason} ->
        {:noreply, fail_session(state, reason)}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, {:ok, info(state)}, state}

  def handle_call({:replay, cursor, limit}, _from, state) do
    {events, state} = replay_events(state, cursor, limit)
    {:reply, {:ok, events}, state}
  end

  def handle_call({:turn_result, turn_id}, _from, state) do
    case Map.fetch(state.results, turn_id) do
      {:ok, result} ->
        {:reply, {:ok, result}, state}

      :error ->
        if MapSet.member?(state.known_turns, turn_id) do
          {:reply, {:pending, info(state)}, state}
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  def handle_call({:send_message, input}, _from, %{status: :idle, active: nil} = state) do
    with {:ok, request} <- TurnRequest.new(input),
         :ok <- validate_turn_request(state, request),
         {:ok, turn_id, state} <- start_turn(state, request, ID.generate("turn")) do
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
         :ok <- validate_turn_request(state, request) do
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
         :ok <- validate_turn_request(state, request),
         :ok <- validate_steer_request(state, request),
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
      false -> {:reply, {:error, unsupported(state, :steer)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:steer, _input}, _from, state), do: {:reply, {:error, :no_active_turn}, state}

  def handle_call({:interrupt, turn_id}, _from, %{active: active} = state) when not is_nil(active) do
    if turn_id in [:active, active.id] do
      case state.session_adapter.interrupt(state.handle, active.id) do
        :ok -> {:reply, :ok, finish_turn(state, :turn_interrupted, %{"reason" => "interrupted"}, nil)}
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
      cancel_timer(approval.timer)

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
      false -> {:reply, {:error, unsupported(state, :approvals)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:configure, changes}, _from, state) when is_map(changes) do
    capabilities = state.transport_spec.capabilities

    with {:ok, changes} <- normalize_configuration(changes),
         {:ok, request} <- validate_configuration(state, changes),
         true <- configuration_supported?(capabilities, changes),
         true <- function_exported?(state.session_adapter, :configure, 2),
         :ok <- state.session_adapter.configure(state.handle, changes) do
      {:reply, :ok, %{state | request: request}}
    else
      false -> {:reply, {:error, unsupported(state, :dynamic_configuration)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  rescue
    exception -> {:reply, {:error, Error.validation("invalid session configuration", cause: exception)}, state}
  end

  def handle_call({:configure, _changes}, _from, state),
    do: {:reply, {:error, Error.validation("session configuration must be a map")}, state}

  def handle_call(:close, _from, state) do
    state = terminate_session(state, :session_closed, %{"reason" => "closed"})
    {:reply, :ok, state}
  end

  def handle_call(:kill, _from, state) do
    state = terminate_session(state, :session_cancelled, %{"reason" => "killed"})
    {:reply, :ok, state}
  end

  def handle_call(:prune, _from, state) when state.status in [:closed, :failed, :cancelled] do
    EventLog.remove(state.journal)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:prune, _from, state), do: {:reply, {:error, :running}, state}

  @impl true
  def handle_info({:session_adapter_event, %Event{} = event}, state) do
    cond do
      SessionInfo.terminal?(info(state)) ->
        {:noreply, state}

      Event.run_terminal?(event) or event.type == :run_started ->
        {:noreply, state}

      Event.session_terminal?(event) ->
        {:noreply, terminate_session(state, event.type, event.payload)}

      true ->
        event = normalize_adapter_event(event, state)
        state = if event.provider_session_id, do: %{state | provider_session_id: event.provider_session_id}, else: state

        if event.type == :approval_requested do
          {:noreply, handle_approval_request(state, event)}
        else
          handle_turn_event(state, event)
        end
    end
  end

  def handle_info(:start_next, %{status: :idle, active: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {turn_id, request}}, queue} ->
        state = %{state | queue: queue} |> append_queue_changed()

        case start_turn(state, request, turn_id) do
          {:ok, _turn_id, state} -> {:noreply, state}
          {:error, reason} -> {:noreply, fail_queued_turn(state, turn_id, request, reason)}
        end

      {:empty, _queue} ->
        {:noreply, state}
    end
  end

  def handle_info(:start_next, state), do: {:noreply, state}

  def handle_info({:session_timeout, :idle, token}, %{session_idle_token: token, status: :idle} = state) do
    {:noreply, terminate_session(state, :session_closed, %{"reason" => "idle_timeout"})}
  end

  def handle_info({:session_timeout, kind, token}, state) when kind in [:runtime, :turn_idle] do
    expected = if kind == :runtime, do: state.turn_runtime_token, else: state.turn_idle_token

    if token == expected and state.active do
      error = Error.new(:timeout, "turn #{kind} timeout exceeded", provider: state.provider)

      case state.session_adapter.interrupt(state.handle, state.active.id) do
        :ok ->
          {:noreply,
           finish_turn(state, :turn_failed, %{"error" => error.message, "timeout" => Atom.to_string(kind)}, error)}

        {:error, reason} ->
          {:noreply, fail_session(state, {:turn_timeout_interrupt_failed, kind, reason})}
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
      {:noreply, fail_session(%{state | handle: nil, handle_monitor: nil}, {:transport_exit, reason})}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_turn_event(state, event) do
    if stale_turn_event?(state, event) do
      {:noreply, state}
    else
      state = schedule_turn_idle(state)

      cond do
        event.type == :turn_started ->
          {:noreply, state}

        (Event.turn_terminal?(event) and state.active) && event.turn_id == state.active.id ->
          {:noreply, finish_turn(state, event.type, event.payload, nil, event)}

        true ->
          {:noreply, append(state, event)}
      end
    end
  end

  @impl true
  def terminate(_reason, state) do
    cancel_timers(state)

    if state.handle do
      _ = state.session_adapter.close(state.handle)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp start_turn(state, request, turn_id) do
    active = %{
      id: turn_id,
      request: request,
      text_tail: TextTail.new(state.buffer.max_bytes),
      final_text_tail: nil,
      usage: %{},
      started_at: timestamp()
    }

    state =
      state
      |> cancel_session_idle()
      |> Map.put(:active, active)
      |> Map.put(:status, :running)
      |> Map.put(:known_turns, MapSet.put(state.known_turns, turn_id))

    case state.session_adapter.send(state.handle, request, turn_id) do
      :ok ->
        state =
          state
          |> append(
            Event.new!(
              type: :input_accepted,
              provider: state.provider,
              turn_id: turn_id,
              payload: %{"kind" => "message"}
            )
          )
          |> append(Event.new!(type: :turn_started, provider: state.provider, turn_id: turn_id, payload: %{}))
          |> schedule_turn_runtime()
          |> schedule_turn_idle()

        {:ok, turn_id, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_turn(state, type, payload, error, event \\ nil, continue_session? \\ true)

  defp finish_turn(state, type, payload, error, event, continue_session?) do
    state = deny_pending_approvals(state, "turn_finished")

    event =
      event ||
        Event.new!(
          type: type,
          provider: state.provider,
          provider_session_id: state.provider_session_id,
          turn_id: state.active.id,
          payload: payload
        )

    state = append(state, event)
    active = state.active

    Enum.each(state.pending_approvals, fn {_id, approval} -> cancel_timer(approval.timer) end)

    status =
      case type do
        :turn_completed -> :completed
        :turn_interrupted -> :interrupted
        :turn_failed -> :failed
      end

    text = active.final_text_tail || active.text_tail

    result = %TurnResult{
      session_id: state.id,
      turn_id: active.id,
      provider: state.provider,
      provider_session_id: state.provider_session_id,
      status: status,
      text: text.data,
      text_truncated?: text.truncated?,
      usage: active.usage,
      events: Enum.filter(Buffer.events(state.buffer), &(&1.turn_id == active.id)),
      metadata: active.request.metadata,
      error: normalize_turn_error(state, error, payload, status)
    }

    cancel_timer(state.turn_runtime_timer)
    cancel_timer(state.turn_idle_timer)

    state = %{
      state
      | active: nil,
        status: if(continue_session?, do: :idle, else: :closing),
        results: Map.put(state.results, active.id, result),
        pending_approvals: %{},
        turn_runtime_timer: nil,
        turn_idle_timer: nil
    }

    if continue_session? do
      state =
        append(state, Event.new!(type: :session_idle, provider: state.provider, payload: %{}))
        |> schedule_session_idle()

      send(self(), :start_next)
      state
    else
      state
    end
  end

  defp fail_queued_turn(state, turn_id, request, reason) do
    active = %{
      id: turn_id,
      request: request,
      text_tail: TextTail.new(state.buffer.max_bytes),
      final_text_tail: nil,
      usage: %{},
      started_at: timestamp()
    }

    state
    |> Map.put(:active, active)
    |> Map.put(:status, :running)
    |> finish_turn(:turn_failed, %{"error" => error_message(reason)}, normalize_error(state, reason))
  end

  defp terminate_session(%{terminal_event: %Event{}} = state, _type, _payload), do: state

  defp terminate_session(state, type, payload) do
    state = %{state | status: :closing}
    state = deny_pending_approvals(state, Map.get(payload, "reason", "session_closed"))

    state =
      if state.active do
        _ = state.session_adapter.interrupt(state.handle, state.active.id)

        finish_turn(
          state,
          :turn_interrupted,
          %{"reason" => Map.get(payload, "reason", "session_closed")},
          nil,
          nil,
          false
        )
      else
        state
      end

    state = cancel_queued(state, Map.get(payload, "reason", "session_closed"))
    _ = if state.handle, do: state.session_adapter.close(state.handle), else: :ok

    event =
      Event.new!(type: type, provider: state.provider, provider_session_id: state.provider_session_id, payload: payload)

    state = append(state, event)

    status =
      case type do
        :session_closed -> :closed
        :session_cancelled -> :cancelled
        :session_failed -> :failed
      end

    :telemetry.execute([:jido, :harness, :session, :stop], %{count: 1}, %{
      session_id: state.id,
      provider: state.provider,
      transport: state.transport_spec.name,
      status: status
    })

    cancel_timers(state)
    %{state | status: status, finished_at: timestamp(), terminal_event: event, handle: nil}
  end

  defp fail_session(state, reason) do
    error = normalize_error(state, reason)

    state =
      if state.active,
        do: finish_turn(state, :turn_failed, %{"error" => error.message}, error, nil, false),
        else: state

    state = %{state | error: error}
    terminate_session(state, :session_failed, %{"error" => error.message})
  end

  defp cancel_queued(state, reason) do
    case :queue.out(state.queue) do
      {{:value, {turn_id, request}}, queue} ->
        active = %{
          id: turn_id,
          request: request,
          text_tail: TextTail.new(state.buffer.max_bytes),
          final_text_tail: nil,
          usage: %{},
          started_at: timestamp()
        }

        state = %{state | queue: queue, active: active, status: :running}
        state = finish_turn(state, :turn_interrupted, %{"reason" => reason}, nil, nil, false)
        cancel_queued(%{state | status: :closing}, reason)

      {:empty, _queue} ->
        %{state | queue: :queue.new(), active: nil}
    end
  end

  defp deny_pending_approvals(state, reason) do
    Enum.reduce(state.pending_approvals, %{state | pending_approvals: %{}}, fn
      {request_id, approval}, state ->
        cancel_timer(approval.timer)

        response = %ApprovalResponse{
          decision: :deny,
          scope: :once,
          reason: reason,
          provider_options: %{}
        }

        if state.handle && function_exported?(state.session_adapter, :respond_approval, 3) do
          _ = state.session_adapter.respond_approval(state.handle, request_id, response)
        end

        append(
          state,
          Event.new!(
            type: :approval_resolved,
            provider: state.provider,
            turn_id: state.active && state.active.id,
            request_id: request_id,
            payload: %{"decision" => "deny", "scope" => "once", "reason" => reason}
          )
        )
    end)
  end

  defp handle_approval_request(state, event) do
    request_id = event.request_id || ID.generate("request")
    event = %{event | request_id: request_id}
    active_turn_id = state.active && state.active.id

    if is_nil(active_turn_id) or event.turn_id != active_turn_id or stale_turn_event?(state, event) do
      _ = deny_approval(state, request_id, "stale approval request")

      append(
        state,
        Event.new!(
          type: :provider_event,
          provider: state.provider,
          request_id: request_id,
          payload: %{"kind" => "stale_approval_denied", "turn_id" => event.turn_id}
        )
      )
    else
      case Map.get(state.pending_approvals, request_id) do
        %{timer: timer} -> cancel_timer(timer)
        nil -> :ok
      end

      timer = approval_timer(state.request.approval_timeout_ms, request_id)
      approvals = Map.put(state.pending_approvals, request_id, %{event: event, timer: timer})
      %{append(state, event) | pending_approvals: approvals, status: :awaiting_approval}
    end
  end

  defp deny_approval(state, request_id, reason) do
    response = %ApprovalResponse{
      decision: :deny,
      scope: :once,
      reason: reason,
      provider_options: %{}
    }

    if state.handle && function_exported?(state.session_adapter, :respond_approval, 3) do
      state.session_adapter.respond_approval(state.handle, request_id, response)
    else
      :ok
    end
  end

  defp append(state, %Event{} = event) do
    event = Event.attach_session(event, state.id, state.provider, state.sequence + 1)
    secrets = Jido.Harness.Redaction.secrets_from_env(state.request.env)
    {buffer, journal} = EventLog.append(state.buffer, state.journal, event, secrets)

    :telemetry.execute([:jido, :harness, :session, :event], %{count: 1}, %{
      session_id: state.id,
      provider: state.provider,
      type: event.type
    })

    state = %{
      state
      | sequence: event.sequence,
        buffer: buffer,
        journal: journal
    }

    accumulate_active(state, event)
  end

  defp accumulate_active(%{active: nil} = state, _event), do: state

  defp accumulate_active(state, %Event{turn_id: turn_id} = event) when turn_id == state.active.id do
    active = state.active

    active =
      case event do
        %Event{type: :output_text_delta, payload: %{"text" => text}} when is_binary(text) ->
          %{active | text_tail: TextTail.append(active.text_tail, text)}

        %Event{type: :output_text_final, payload: %{"text" => text}} when is_binary(text) ->
          %{active | final_text_tail: TextTail.replace(active.text_tail, text)}

        %Event{type: :usage, payload: payload} ->
          %{active | usage: Map.merge(active.usage, payload)}

        _ ->
          active
      end

    %{state | active: active}
  end

  defp accumulate_active(state, _event), do: state

  defp normalize_adapter_event(event, state) do
    turn_id = event.turn_id || (state.active && state.active.id)
    %{event | run_id: nil, session_id: nil, turn_id: turn_id}
  end

  defp append_queue_changed(state) do
    append(
      state,
      Event.new!(
        type: :queue_changed,
        provider: state.provider,
        payload: %{"queued_turns" => :queue.len(state.queue)}
      )
    )
  end

  defp replay_events(state, cursor, limit) do
    {records, journal, available_from} = EventLog.replay(state.buffer, state.journal, cursor, limit)
    events = Enum.map(records, &record_to_event(state, &1))
    {prepend_gap(events, state, cursor, available_from), %{state | journal: journal}}
  end

  defp prepend_gap(events, _state, cursor, available_from) when cursor >= available_from - 1, do: events

  defp prepend_gap(events, state, _cursor, available_from) do
    gap =
      Event.new!(
        type: :provider_event,
        session_id: state.id,
        provider: state.provider,
        provider_session_id: state.provider_session_id,
        sequence: max(1, available_from - 1),
        payload: %{"kind" => "replay_gap", "available_from" => available_from}
      )

    [gap | events]
  end

  defp record_to_event(_state, %Event{} = event), do: event

  defp record_to_event(state, record) do
    Event.new!(
      type: existing_atom(record["type"]),
      run_id: nil,
      session_id: record["session_id"] || state.id,
      provider: existing_atom(record["provider"] || Atom.to_string(state.provider)),
      provider_session_id: record["provider_session_id"],
      turn_id: record["turn_id"],
      request_id: record["request_id"],
      sequence: record["sequence"],
      timestamp: record["timestamp"],
      payload: record["payload"] || %{},
      raw: nil
    )
  end

  defp info(state) do
    %SessionInfo{
      session_id: state.id,
      provider: state.provider,
      provider_session_id: state.provider_session_id,
      state: state.status,
      active_turn_id: state.active && state.active.id,
      started_at: state.started_at,
      finished_at: state.finished_at,
      error: state.error,
      journal_dir: EventLog.dir(state.journal),
      transport: state.transport_spec.name,
      output_cursor: state.sequence,
      queued_turns: :queue.len(state.queue),
      pending_approvals: map_size(state.pending_approvals),
      metadata: state.request.metadata
    }
  end

  defp schedule_session_idle(%{request: %{session_idle_timeout_ms: :infinity}} = state), do: state

  defp schedule_session_idle(state) do
    state = cancel_session_idle(state)
    token = make_ref()
    timer = Process.send_after(self(), {:session_timeout, :idle, token}, state.request.session_idle_timeout_ms)
    %{state | session_idle_timer: timer, session_idle_token: token}
  end

  defp cancel_session_idle(state) do
    cancel_timer(state.session_idle_timer)
    %{state | session_idle_timer: nil, session_idle_token: nil}
  end

  defp schedule_turn_runtime(%{request: %{turn_runtime_timeout_ms: :infinity}} = state), do: state

  defp schedule_turn_runtime(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:session_timeout, :runtime, token}, state.request.turn_runtime_timeout_ms)
    %{state | turn_runtime_timer: timer, turn_runtime_token: token}
  end

  defp schedule_turn_idle(%{active: nil} = state), do: state
  defp schedule_turn_idle(%{request: %{turn_idle_timeout_ms: :infinity}} = state), do: state

  defp schedule_turn_idle(state) do
    cancel_timer(state.turn_idle_timer)
    token = make_ref()
    timer = Process.send_after(self(), {:session_timeout, :turn_idle, token}, state.request.turn_idle_timeout_ms)
    %{state | turn_idle_timer: timer, turn_idle_token: token}
  end

  defp cancel_timers(state) do
    cancel_timer(state.session_idle_timer)
    cancel_timer(state.turn_runtime_timer)
    cancel_timer(state.turn_idle_timer)
    :ok
  end

  defp normalize_turn_error(_state, nil, _payload, status) when status in [:completed, :interrupted], do: nil

  defp normalize_turn_error(state, nil, payload, :failed),
    do: Error.execution(Map.get(payload, "error", "turn failed"), provider: state.provider)

  defp normalize_turn_error(state, error, _payload, _status), do: normalize_error(state, error)

  defp normalize_error(state, %Error{} = error), do: %{error | provider: error.provider || state.provider}

  defp normalize_error(state, reason),
    do: Error.execution("interactive session failed", provider: state.provider, cause: reason)

  defp unsupported(state, capability) do
    Error.validation("session transport does not support capability",
      provider: state.provider,
      details: %{transport: state.transport_spec.name, capability: capability}
    )
  end

  defp validate_configuration(state, changes) do
    allowed = state.transport_spec.configuration_options

    case Enum.find(Map.keys(changes), &(&1 not in allowed)) do
      nil ->
        with {:ok, request} <-
               state.request
               |> Map.from_struct()
               |> Map.merge(changes)
               |> SessionRequest.new(),
             :ok <- validate_configured_values(state, changes) do
          {:ok, request}
        end

      field ->
        {:error,
         Error.validation("unsupported session configuration",
           provider: state.provider,
           details: %{field: field}
         )}
    end
  end

  defp normalize_configuration(changes) do
    allowed = [:model, :reasoning_effort, :approval_mode, :sandbox_mode]
    allowed_strings = Map.new(allowed, &{Atom.to_string(&1), &1})

    Enum.reduce_while(changes, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      normalized_key =
        cond do
          is_atom(key) and key in allowed -> key
          is_binary(key) -> Map.get(allowed_strings, key)
          true -> nil
        end

      if normalized_key do
        {:cont, {:ok, Map.put(normalized, normalized_key, value)}}
      else
        {:halt, {:error, Error.validation("unsupported session configuration", details: %{field: key})}}
      end
    end)
  end

  defp configuration_supported?(capabilities, changes) do
    model? = Map.has_key?(changes, :model)

    (not model? or InteractionCapabilities.supported?(capabilities, :dynamic_model)) and
      InteractionCapabilities.supported?(capabilities, :dynamic_configuration)
  end

  defp validate_turn_request(state, request) do
    capabilities = state.transport_spec.capabilities
    turn_options = transport_options(state.transport_spec.turn_options, state.adapter.spec().normalized_options)

    cond do
      not is_nil(request.output_schema) and not InteractionCapabilities.supported?(capabilities, :structured_output) ->
        {:error, unsupported(state, :structured_output)}

      multimodal?(request) and not InteractionCapabilities.supported?(capabilities, :multimodal) ->
        {:error, unsupported(state, :multimodal)}

      field = unsupported_turn_option(request, turn_options) ->
        {:error,
         Error.validation("session transport does not support turn option",
           provider: state.provider,
           details: %{transport: state.transport_spec.name, field: field}
         )}

      path = invalid_attachment(state, request) ->
        {:error,
         Error.validation("turn attachment must be an existing file",
           provider: state.provider,
           details: %{path: path}
         )}

      true ->
        validate_turn_provider_options(state, request.provider_options)
    end
  end

  defp validate_turn_provider_options(state, options) do
    supported =
      transport_options(state.transport_spec.turn_provider_options, state.adapter.spec().provider_options)

    supported_strings = Map.new(supported, &{Atom.to_string(&1), &1})

    case Enum.find(Map.keys(options), fn
           key when is_atom(key) -> key not in supported
           key when is_binary(key) -> not Map.has_key?(supported_strings, key)
           _key -> true
         end) do
      nil ->
        :ok

      key ->
        {:error,
         Error.validation("unknown turn provider option",
           provider: state.provider,
           details: %{key: key}
         )}
    end
  end

  defp multimodal?(request) do
    request.attachments != [] or
      Enum.any?(request.content, fn block -> Map.get(block, :type) not in [:text, "text"] end)
  end

  defp unsupported_turn_option(request, supported) do
    cond do
      not is_nil(request.reasoning_effort) and :reasoning_effort not in supported -> :reasoning_effort
      not is_nil(request.output_schema) and :output_schema not in supported -> :output_schema
      request.attachments != [] and :attachments not in supported -> :attachments
      multimodal_content?(request) and :content not in supported -> :content
      true -> nil
    end
  end

  defp multimodal_content?(request) do
    Enum.any?(request.content, fn block -> Map.get(block, :type) not in [:text, "text"] end)
  end

  defp invalid_attachment(state, request) do
    Enum.find(request.attachments, fn path ->
      not File.regular?(Path.expand(path, state.request.cwd))
    end)
  end

  defp validate_steer_request(state, request) do
    field =
      cond do
        not is_nil(request.reasoning_effort) -> :reasoning_effort
        not is_nil(request.output_schema) -> :output_schema
        map_size(request.provider_options) > 0 -> :provider_options
        true -> nil
      end

    if field do
      {:error,
       Error.validation("session transport does not support steering option",
         provider: state.provider,
         details: %{transport: state.transport_spec.name, field: field}
       )}
    else
      :ok
    end
  end

  defp transport_options(:adapter, adapter_options), do: adapter_options
  defp transport_options(options, _adapter_options), do: options

  defp validate_configured_values(state, changes) do
    normalized_values = state.adapter.spec().normalized_values

    Enum.reduce_while(changes, :ok, fn {field, value}, :ok ->
      case Map.get(normalized_values, field) do
        nil ->
          {:cont, :ok}

        allowed ->
          if value in allowed do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              Error.validation("unsupported value for session configuration",
                provider: state.provider,
                details: %{field: field, value: value, allowed: allowed}
              )}}
          end
      end
    end)
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

  defp error_message(%Error{message: message}), do: message
  defp error_message(reason), do: inspect(reason)
  defp existing_atom(value) when is_atom(value), do: value
  defp existing_atom(value) when is_binary(value), do: String.to_existing_atom(value)
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: true, info: false)
  defp approval_timer(:infinity, _request_id), do: nil
  defp approval_timer(timeout, request_id), do: Process.send_after(self(), {:approval_timeout, request_id}, timeout)
  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
