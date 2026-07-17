defmodule Jido.Harness.Session.Lifecycle do
  @moduledoc false

  alias Jido.Harness.{ApprovalResponse, Buffer, Error, Event, ID, TurnResult, Waiters}
  alias Jido.Harness.Session.{ActiveTurn, EventStore, State, Timers}

  @doc false
  @spec start_turn(State.t(), Jido.Harness.TurnRequest.t(), String.t()) ::
          {:ok, String.t(), State.t()} | {:error, term()}
  def start_turn(state, request, turn_id) do
    active = ActiveTurn.new(turn_id, request, state.buffer.max_bytes)

    state =
      state
      |> Timers.cancel_session_idle()
      |> Map.put(:active, active)
      |> Map.put(:status, :running)
      |> Map.put(:known_turns, MapSet.put(state.known_turns, turn_id))

    case state.session_adapter.send(state.handle, request, turn_id) do
      :ok ->
        state =
          state
          |> EventStore.append(
            Event.new!(
              type: :input_accepted,
              provider: state.provider,
              turn_id: turn_id,
              payload: %{"kind" => "message"}
            )
          )
          |> EventStore.append(
            Event.new!(type: :turn_started, provider: state.provider, turn_id: turn_id, payload: %{})
          )
          |> Timers.schedule_turn_runtime()
          |> Timers.schedule_turn_idle()

        {:ok, turn_id, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec finish_turn(State.t(), atom(), map(), term(), Event.t() | nil, boolean()) :: State.t()
  def finish_turn(state, type, payload, error, event \\ nil, continue_session? \\ true)

  def finish_turn(state, type, payload, error, event, continue_session?) do
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

    state = EventStore.append(state, event)
    active = state.active

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

    Timers.cancel(state.turn_runtime_timer)
    Timers.cancel(state.turn_idle_timer)
    waiters = Waiters.reply(state.waiters, active.id, {:ok, result})

    state = %{
      state
      | active: nil,
        status: if(continue_session?, do: :idle, else: :closing),
        results: Map.put(state.results, active.id, result),
        pending_approvals: %{},
        turn_runtime_timer: nil,
        turn_idle_timer: nil,
        waiters: waiters
    }

    if continue_session? do
      state =
        state
        |> EventStore.append(Event.new!(type: :session_idle, provider: state.provider, payload: %{}))
        |> Timers.schedule_session_idle()

      send(self(), :start_next)
      state
    else
      state
    end
  end

  @doc false
  @spec fail_queued_turn(State.t(), String.t(), Jido.Harness.TurnRequest.t(), term()) :: State.t()
  def fail_queued_turn(state, turn_id, request, reason) do
    active = ActiveTurn.new(turn_id, request, state.buffer.max_bytes)

    state
    |> Map.put(:active, active)
    |> Map.put(:status, :running)
    |> finish_turn(:turn_failed, %{"error" => error_message(reason)}, normalize_error(state, reason))
  end

  @doc false
  @spec terminate_session(State.t(), atom(), map()) :: State.t()
  def terminate_session(%{terminal_event: %Event{}} = state, _type, _payload), do: state

  def terminate_session(state, type, payload) do
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

    state = EventStore.append(state, event)

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

    Timers.cancel_all(state)
    %{state | status: status, finished_at: timestamp(), terminal_event: event, handle: nil}
  end

  @doc false
  @spec fail_session(State.t(), term()) :: State.t()
  def fail_session(state, reason) do
    error = normalize_error(state, reason)

    state =
      if state.active,
        do: finish_turn(state, :turn_failed, %{"error" => error.message}, error, nil, false),
        else: state

    state = %{state | error: error}
    terminate_session(state, :session_failed, %{"error" => error.message})
  end

  @doc false
  @spec handle_approval_request(State.t(), Event.t()) :: State.t()
  def handle_approval_request(state, event) do
    request_id = event.request_id || ID.generate("request")
    event = %{event | request_id: request_id}
    active_turn_id = state.active && state.active.id

    if is_nil(active_turn_id) or event.turn_id != active_turn_id or stale_turn_event?(state, event) do
      _ = deny_approval(state, request_id, "stale approval request")

      EventStore.append(
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
        %{timer: timer} -> Timers.cancel(timer)
        nil -> :ok
      end

      timer = Timers.approval(state.request.approval_timeout_ms, request_id)
      approvals = Map.put(state.pending_approvals, request_id, %{event: event, timer: timer})
      %{EventStore.append(state, event) | pending_approvals: approvals, status: :awaiting_approval}
    end
  end

  defp cancel_queued(state, reason) do
    case :queue.out(state.queue) do
      {{:value, {turn_id, request}}, queue} ->
        active = ActiveTurn.new(turn_id, request, state.buffer.max_bytes)
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
        Timers.cancel(approval.timer)

        response = %ApprovalResponse{
          decision: :deny,
          scope: :once,
          reason: reason,
          provider_options: %{}
        }

        if state.handle && function_exported?(state.session_adapter, :respond_approval, 3) do
          _ = state.session_adapter.respond_approval(state.handle, request_id, response)
        end

        EventStore.append(
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

  defp normalize_turn_error(_state, nil, _payload, status) when status in [:completed, :interrupted], do: nil

  defp normalize_turn_error(state, nil, payload, :failed),
    do: Error.execution(Map.get(payload, "error", "turn failed"), provider: state.provider)

  defp normalize_turn_error(state, error, _payload, _status), do: normalize_error(state, error)

  defp normalize_error(state, %Error{} = error), do: %{error | provider: error.provider || state.provider}

  defp normalize_error(state, reason),
    do: Error.execution("interactive session failed", provider: state.provider, cause: reason)

  defp stale_turn_event?(state, %Event{turn_id: turn_id}) when is_binary(turn_id),
    do: Map.has_key?(state.results, turn_id)

  defp stale_turn_event?(_state, _event), do: false

  defp error_message(%Error{message: message}), do: message
  defp error_message(reason), do: inspect(reason)
  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
