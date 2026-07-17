defmodule Jido.Harness.Session.EventStore do
  @moduledoc false

  alias Jido.Harness.{Event, EventLog, Redaction, SessionInfo, TextTail}
  alias Jido.Harness.Session.State

  @doc false
  @spec append(State.t(), Event.t()) :: State.t()
  def append(state, %Event{} = event) do
    event = Event.attach_session(event, state.id, state.provider, state.sequence + 1)
    secrets = Redaction.secrets_from_env(state.request.env)
    {buffer, journal} = EventLog.append(state.buffer, state.journal, event, secrets)

    :telemetry.execute([:jido, :harness, :session, :event], %{count: 1}, %{
      session_id: state.id,
      provider: state.provider,
      type: event.type
    })

    state
    |> Map.put(:sequence, event.sequence)
    |> Map.put(:buffer, buffer)
    |> Map.put(:journal, journal)
    |> accumulate_active(event)
  end

  @doc false
  @spec normalize_adapter_event(Event.t(), State.t()) :: Event.t()
  def normalize_adapter_event(event, state) do
    turn_id = event.turn_id || (state.active && state.active.id)
    %{event | run_id: nil, session_id: nil, turn_id: turn_id}
  end

  @doc false
  @spec append_queue_changed(State.t()) :: State.t()
  def append_queue_changed(state) do
    append(
      state,
      Event.new!(
        type: :queue_changed,
        provider: state.provider,
        payload: %{"queued_turns" => :queue.len(state.queue)}
      )
    )
  end

  @doc false
  @spec replay(State.t(), non_neg_integer(), pos_integer()) :: {[Event.t()], State.t()}
  def replay(state, cursor, limit) do
    {records, journal, available_from} = EventLog.replay(state.buffer, state.journal, cursor, limit)
    events = Enum.map(records, &record_to_event(state, &1))
    {prepend_gap(events, state, cursor, available_from), %{state | journal: journal}}
  end

  @doc false
  @spec info(State.t()) :: SessionInfo.t()
  def info(state) do
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

  defp existing_atom(value) when is_atom(value), do: value
  defp existing_atom(value) when is_binary(value), do: String.to_existing_atom(value)
end
