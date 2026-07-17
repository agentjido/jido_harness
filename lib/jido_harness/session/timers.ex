defmodule Jido.Harness.Session.Timers do
  @moduledoc false

  alias Jido.Harness.Session.State

  @doc false
  @spec schedule_session_idle(State.t()) :: State.t()
  def schedule_session_idle(%{request: %{session_idle_timeout_ms: :infinity}} = state), do: state

  def schedule_session_idle(state) do
    state = cancel_session_idle(state)
    token = make_ref()
    timer = Process.send_after(self(), {:session_timeout, :idle, token}, state.request.session_idle_timeout_ms)
    %{state | session_idle_timer: timer, session_idle_token: token}
  end

  @doc false
  @spec cancel_session_idle(State.t()) :: State.t()
  def cancel_session_idle(state) do
    cancel(state.session_idle_timer)
    %{state | session_idle_timer: nil, session_idle_token: nil}
  end

  @doc false
  @spec schedule_turn_runtime(State.t()) :: State.t()
  def schedule_turn_runtime(%{request: %{turn_runtime_timeout_ms: :infinity}} = state), do: state

  def schedule_turn_runtime(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:session_timeout, :runtime, token}, state.request.turn_runtime_timeout_ms)
    %{state | turn_runtime_timer: timer, turn_runtime_token: token}
  end

  @doc false
  @spec schedule_turn_idle(State.t()) :: State.t()
  def schedule_turn_idle(%{active: nil} = state), do: state
  def schedule_turn_idle(%{request: %{turn_idle_timeout_ms: :infinity}} = state), do: state

  def schedule_turn_idle(state) do
    cancel(state.turn_idle_timer)
    token = make_ref()
    timer = Process.send_after(self(), {:session_timeout, :turn_idle, token}, state.request.turn_idle_timeout_ms)
    %{state | turn_idle_timer: timer, turn_idle_token: token}
  end

  @doc false
  @spec cancel_all(State.t()) :: :ok
  def cancel_all(state) do
    cancel(state.session_idle_timer)
    cancel(state.turn_runtime_timer)
    cancel(state.turn_idle_timer)
    :ok
  end

  @doc false
  @spec cancel(reference() | nil) :: :ok
  def cancel(nil), do: :ok
  def cancel(timer), do: Process.cancel_timer(timer, async: true, info: false)

  @doc false
  @spec approval(:infinity | non_neg_integer(), String.t()) :: reference() | nil
  def approval(:infinity, _request_id), do: nil
  def approval(timeout, request_id), do: Process.send_after(self(), {:approval_timeout, request_id}, timeout)
end
