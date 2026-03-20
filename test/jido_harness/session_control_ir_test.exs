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

  test "session handles expose stable metadata only" do
    {:ok, session} =
      SessionHandle.new(%{
        session_id: "session-transport-1",
        runtime_id: :jido_session,
        provider: :jido_session,
        metadata: %{"surface" => "runtime-driver"}
      })

    refute Map.has_key?(Map.from_struct(session), :driver_ref)
    assert session.metadata == %{"surface" => "runtime-driver"}
  end

  test "session control ir structs retain the stable public field set" do
    session =
      SessionHandle.new!(%{
        session_id: "session-shape-1",
        runtime_id: :asm,
        provider: :claude
      })

    run =
      RunHandle.new!(%{
        run_id: "run-shape-1",
        session_id: session.session_id,
        runtime_id: :asm,
        provider: :claude
      })

    event =
      ExecutionEvent.new!(%{
        event_id: "event-shape-1",
        type: :result,
        session_id: session.session_id,
        run_id: run.run_id,
        runtime_id: :asm,
        provider: :claude,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    result =
      ExecutionResult.new!(%{
        run_id: run.run_id,
        session_id: session.session_id,
        runtime_id: :asm,
        provider: :claude,
        status: :completed
      })

    descriptor =
      RuntimeDescriptor.new!(%{
        runtime_id: :asm,
        provider: :claude,
        label: "ASM",
        session_mode: :external
      })

    assert session |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
             [:metadata, :provider, :runtime_id, :schema_version, :session_id, :status]

    assert run |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
             [:metadata, :provider, :run_id, :runtime_id, :schema_version, :session_id, :started_at, :status]

    assert event |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
             [
               :event_id,
               :metadata,
               :payload,
               :provider,
               :raw,
               :run_id,
               :runtime_id,
               :schema_version,
               :sequence,
               :session_id,
               :status,
               :timestamp,
               :type
             ]

    assert result |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
             [
               :cost,
               :duration_ms,
               :error,
               :messages,
               :metadata,
               :provider,
               :run_id,
               :runtime_id,
               :schema_version,
               :session_id,
               :status,
               :stop_reason,
               :text
             ]

    assert descriptor |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
             [
               :approvals?,
               :cancellation?,
               :cost?,
               :label,
               :metadata,
               :provider,
               :resume?,
               :runtime_id,
               :schema_version,
               :session_mode,
               :streaming?,
               :subscribe?
             ]
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
