defmodule Jido.Harness.SessionControl do
  @moduledoc """
  Version marker for the shared Session Control IR.

  Boundary-backed runtimes keep the IR field set stable and carry live
  boundary descriptors or attach metadata under one reserved metadata key
  instead of widening the public structs with sandbox-specific fields.

  The canonical lower-boundary packet carried around Harness is:

  - `BoundarySessionDescriptor.v1`
  - `ExecutionRoute.v1`
  - `AttachGrant.v1`
  - `CredentialHandleRef.v1`
  - `ExecutionEvent.v1`
  - `ExecutionOutcome.v1`
  - `ProcessExecutionIntent.v1`
  - `JsonRpcExecutionIntent.v1`

  The named Wave 5 boundary metadata groups carried by the facade layer are:

  - `descriptor`
  - `route`
  - `attach_grant`
  - `replay`
  - `approval`
  - `callback`
  - `identity`

  Harness maps those contracts into its own public driver IR. It does not
  become the raw Execution Plane public API. The family-facing minimal-lane
  carrier details remain provisional until Wave 3 prove-out.
  """

  @version "session_control/v1"
  @boundary_metadata_key "boundary"
  @boundary_contract_keys [
    "descriptor",
    "route",
    "attach_grant",
    "replay",
    "approval",
    "callback",
    "identity"
  ]
  @mapped_execution_contracts [
    "BoundarySessionDescriptor.v1",
    "ExecutionRoute.v1",
    "AttachGrant.v1",
    "CredentialHandleRef.v1",
    "ExecutionEvent.v1",
    "ExecutionOutcome.v1",
    "ProcessExecutionIntent.v1",
    "JsonRpcExecutionIntent.v1"
  ]
  @provisional_minimal_lane_contracts [
    "ProcessExecutionIntent.v1",
    "JsonRpcExecutionIntent.v1"
  ]

  @doc "Returns the current Session Control schema version."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Returns the reserved metadata key for live boundary descriptor carriage."
  @spec boundary_metadata_key() :: String.t()
  def boundary_metadata_key, do: @boundary_metadata_key

  @doc "Returns the explicit boundary metadata subcontracts carried by Harness."
  @spec boundary_contract_keys() :: [String.t(), ...]
  def boundary_contract_keys, do: @boundary_contract_keys

  @doc "Returns the canonical lower-boundary contract names carried by Harness."
  @spec mapped_execution_contracts() :: [String.t(), ...]
  def mapped_execution_contracts, do: @mapped_execution_contracts

  @doc "Returns the lower family-intent shapes still provisional until Wave 3."
  @spec provisional_minimal_lane_contracts() :: [String.t(), ...]
  def provisional_minimal_lane_contracts, do: @provisional_minimal_lane_contracts
end
