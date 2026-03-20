defmodule Jido.Harness.RuntimeDriver do
  @moduledoc """
  Behaviour for runtime drivers that implement the Session Control IR.

  Drivers must always expose the session lifecycle callbacks required for
  start/stop, streaming runs, cancellation, and status. Optional callbacks for
  synchronous `run/3`, approvals, cost inspection, subscription, and resume
  semantics should only be advertised when the corresponding
  `Jido.Harness.RuntimeDescriptor` capability flags are true.
  """

  alias Jido.Harness.{
    ExecutionEvent,
    ExecutionResult,
    ExecutionStatus,
    RunHandle,
    RunRequest,
    RuntimeDescriptor,
    SessionHandle
  }

  @callback runtime_id() :: atom()
  @callback runtime_descriptor(keyword()) :: RuntimeDescriptor.t()
  @callback start_session(keyword()) :: {:ok, SessionHandle.t()} | {:error, term()}
  @callback stop_session(SessionHandle.t()) :: :ok | {:error, term()}

  @callback stream_run(SessionHandle.t(), RunRequest.t(), keyword()) ::
              {:ok, RunHandle.t(), Enumerable.t(ExecutionEvent.t())} | {:error, term()}

  @callback cancel_run(SessionHandle.t(), RunHandle.t() | String.t()) :: :ok | {:error, term()}
  @callback session_status(SessionHandle.t()) :: {:ok, ExecutionStatus.t()} | {:error, term()}

  @callback run(SessionHandle.t(), RunRequest.t(), keyword()) ::
              {:ok, ExecutionResult.t()} | {:error, term()}

  @callback approve(SessionHandle.t(), String.t(), :allow | :deny, keyword()) ::
              :ok | {:error, term()}

  @callback cost(SessionHandle.t()) :: {:ok, map()} | {:error, term()}
  @callback subscribe(SessionHandle.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback resume(SessionHandle.t(), RunHandle.t() | String.t(), keyword()) ::
              {:ok, RunHandle.t()} | {:error, term()}

  @optional_callbacks run: 3, approve: 4, cost: 1, subscribe: 2, resume: 3
end
