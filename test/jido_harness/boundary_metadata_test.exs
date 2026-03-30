defmodule Jido.Harness.BoundaryMetadataTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.{
    ExecutionResult,
    ExecutionStatus,
    RuntimeDescriptor,
    SessionControl,
    SessionHandle
  }

  test "session control publishes the boundary metadata namespace" do
    assert SessionControl.boundary_metadata_key() == "boundary"
  end

  test "runtime ir structs carry boundary metadata without widening the stable field set" do
    boundary_key = SessionControl.boundary_metadata_key()

    boundary_metadata = %{
      boundary_key => %{
        "descriptor_version" => 1,
        "boundary_session_id" => "bnd-123",
        "attach" => %{"mode" => "guest_bridge"},
        "checkpointing" => %{"supported?" => true}
      }
    }

    descriptor =
      RuntimeDescriptor.new!(%{
        runtime_id: :asm,
        provider: :codex,
        label: "ASM",
        session_mode: :external,
        metadata: boundary_metadata
      })

    session =
      SessionHandle.new!(%{
        session_id: "session-boundary-1",
        runtime_id: :asm,
        provider: :codex,
        metadata: boundary_metadata
      })

    status =
      ExecutionStatus.new!(%{
        runtime_id: :asm,
        session_id: session.session_id,
        scope: :session,
        state: :ready,
        details: boundary_metadata
      })

    result =
      ExecutionResult.new!(%{
        run_id: "run-boundary-1",
        session_id: session.session_id,
        runtime_id: :asm,
        provider: :codex,
        status: :completed,
        metadata: boundary_metadata
      })

    assert descriptor.metadata[boundary_key]["boundary_session_id"] == "bnd-123"
    assert session.metadata[boundary_key]["attach"]["mode"] == "guest_bridge"
    assert status.details[boundary_key]["checkpointing"]["supported?"] == true
    assert result.metadata[boundary_key]["descriptor_version"] == 1
  end
end
