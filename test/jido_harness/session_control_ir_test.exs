defmodule Jido.Harness.SessionControlIRTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.{
    ExecutionEvent,
    ExecutionResult,
    ExecutionStatus,
    RunHandle,
    RuntimeDescriptor,
    SessionControl,
    SessionHandle
  }

  test "session control ir schemas validate required fields" do
    assert SessionControl.version() == "session_control/v1"

    assert {:ok, %SessionHandle{session_id: "session-1", schema_version: "session_control/v1"}} =
             SessionHandle.new(%{
               session_id: "session-1",
               runtime_id: :asm,
               provider: :claude,
               status: :ready
             })

    assert {:ok, %RunHandle{run_id: "run-1"}} =
             RunHandle.new(%{
               run_id: "run-1",
               session_id: "session-1",
               runtime_id: :asm,
               provider: :claude,
               status: :running
             })

    assert {:ok, %ExecutionStatus{scope: :session, state: :ready}} =
             ExecutionStatus.new(%{
               runtime_id: :asm,
               session_id: "session-1",
               scope: :session,
               state: :ready
             })

    assert {:ok, %ExecutionEvent{type: :run_started, event_id: "event-1"}} =
             ExecutionEvent.new(%{
               event_id: "event-1",
               type: :run_started,
               session_id: "session-1",
               run_id: "run-1",
               runtime_id: :asm,
               provider: :claude,
               timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
             })

    assert {:ok, %ExecutionResult{run_id: "run-1", status: :completed}} =
             ExecutionResult.new(%{
               run_id: "run-1",
               session_id: "session-1",
               runtime_id: :asm,
               provider: :claude,
               status: :completed
             })

    assert {:ok, %RuntimeDescriptor{runtime_id: :asm, provider: :claude}} =
             RuntimeDescriptor.new(%{
               runtime_id: :asm,
               provider: :claude,
               label: "ASM",
               session_mode: :external
             })
  end

  test "session control ir constructors reject invalid inputs" do
    assert {:error, _} = SessionHandle.new(%{})
    assert {:error, _} = RunHandle.new(%{})
    assert {:error, _} = ExecutionStatus.new(%{})
    assert {:error, _} = ExecutionEvent.new(%{})
    assert {:error, _} = ExecutionResult.new(%{})
    assert {:error, _} = RuntimeDescriptor.new(%{})
  end
end
