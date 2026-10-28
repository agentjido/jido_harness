defmodule Jido.Harness.Session.SignalStore do
  @moduledoc false

  alias Jido.Harness.{Redaction, SessionInfo, Signal, SignalLog, TextTail}
  alias Jido.Harness.Adapter.Message
  alias Jido.Harness.Session.State

  @doc false
  @spec append(State.t(), Message.t()) :: State.t()
  def append(state, %Message{} = message) do
    {:ok, signal} =
      Signal.from_adapter(message, :session, state.id, state.provider, state.sequence + 1, state.request.metadata)

    secrets = state.secrets || Redaction.prepare(Redaction.secrets_from_env(state.request.env))
    {buffer, signal_log} = SignalLog.append(state.buffer, state.signal_log, signal, secrets)

    :telemetry.execute([:jido, :harness, :session, :signal], %{count: 1}, %{
      session_id: state.id,
      provider: state.provider,
      type: signal.type
    })

    state
    |> Map.put(:sequence, Signal.sequence(signal))
    |> Map.put(:buffer, buffer)
    |> Map.put(:signal_log, signal_log)
    |> Map.put(:secrets, secrets)
    |> accumulate_active(signal)
  end

  @doc false
  @spec normalize_adapter_message(Message.t(), State.t()) :: Message.t()
  def normalize_adapter_message(message, state) do
    turn_id = message.turn_id || (state.active && state.active.id)
    %{message | turn_id: turn_id}
  end

  @doc false
  @spec append_queue_changed(State.t()) :: State.t()
  def append_queue_changed(state) do
    append(
      state,
      Message.new!(
        type: :queue_changed,
        payload: %{"queued_turns" => :queue.len(state.queue)}
      )
    )
  end

  @doc false
  @spec replay(State.t(), non_neg_integer(), pos_integer()) :: {[Jido.Signal.t()], State.t()}
  def replay(state, cursor, limit) do
    {page, signal_log} = SignalLog.replay(state.signal_log, cursor, limit, 1_048_576, &record_to_signal(state, &1))
    signals = SignalLog.signals(page, &Function.identity/1, &gap_signal(state, &1))
    {signals, %{state | signal_log: signal_log}}
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
      journal_dir: SignalLog.dir(state.signal_log),
      replay_store: SignalLog.info(state.signal_log),
      output_cursor: state.sequence,
      queued_turns: :queue.len(state.queue),
      pending_approvals: map_size(state.pending_approvals),
      metadata: state.request.metadata
    }
  end

  defp accumulate_active(%{active: nil} = state, _signal), do: state

  defp accumulate_active(state, %Jido.Signal{} = signal) do
    if signal.data["turn_id"] == state.active.id do
      accumulate_active_turn(state, Signal.kind(signal), signal.data["payload"] || %{})
    else
      state
    end
  end

  defp accumulate_active_turn(state, kind, payload) do
    active = state.active

    active =
      case {kind, payload} do
        {:output_text_delta, %{"text" => text}} when is_binary(text) ->
          %{active | text_tail: TextTail.append(active.text_tail, text)}

        {:output_text_final, %{"text" => text}} when is_binary(text) ->
          %{active | final_text_tail: TextTail.replace(active.text_tail, text)}

        {:usage, payload} ->
          %{active | usage: Map.merge(active.usage, payload)}

        _ ->
          active
      end

    %{state | active: active}
  end

  defp gap_signal(state, gap), do: Signal.replay_gap(:session, state.id, gap, state.request.metadata)

  @doc false
  @spec record_to_signal(State.t(), map()) :: Jido.Signal.t()
  def record_to_signal(_state, %Jido.Signal{} = signal), do: signal

  def record_to_signal(_state, %{"format_version" => 2, "signal" => wire}) do
    {:ok, signal} = Jido.Signal.Catalog.decode(Signal.catalog(), wire)
    signal
  end
end
