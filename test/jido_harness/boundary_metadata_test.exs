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

    assert SessionControl.boundary_contract_keys() == [
             "descriptor",
             "route",
             "attach_grant",
             "replay",
             "approval",
             "callback",
             "identity"
           ]
  end

  test "runtime ir structs carry boundary metadata without widening the stable field set" do
    boundary_key = SessionControl.boundary_metadata_key()

    boundary_metadata = %{
      boundary_key => %{
        "descriptor" => %{
          "descriptor_version" => 1,
          "boundary_session_id" => "bnd-123"
        },
        "route" => %{"route_id" => "route-123", "idempotency_key" => "idem-123"},
        "attach_grant" => %{"attach_mode" => "read_write"},
        "replay" => %{"replayable?" => true},
        "approval" => %{"approval_refs" => ["approval-123"]},
        "callback" => %{"callback_ref" => "callback://123", "state" => "pending"},
        "identity" => %{
          "credential_handle_refs" => ["credential-handle://tenant-1/workload/123"]
        }
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

    assert descriptor.metadata[boundary_key]["descriptor"]["boundary_session_id"] == "bnd-123"
    assert session.metadata[boundary_key]["route"]["route_id"] == "route-123"
    assert status.details[boundary_key]["replay"]["replayable?"] == true

    assert result.metadata[boundary_key]["identity"]["credential_handle_refs"] == [
             "credential-handle://tenant-1/workload/123"
           ]
  end
end
