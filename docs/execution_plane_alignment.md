# Execution Plane Alignment

`jido_harness` remains the public runtime-driver and facade IR layer above the
Execution Plane.

## Role

Harness may:

- carry lower-boundary contracts
- map them into public runtime-driver IR
- expose stable facade semantics for runtime drivers

Harness must not:

- become the raw Execution Plane public API
- reclaim transport ownership
- reinterpret Brain or Spine policy locally

## Frozen Packet Vocabulary

The canonical lower-boundary contract names that must remain consistent with
the packet and Wave 5 session carriage are:

- `BoundarySessionDescriptor.v1`
- `ExecutionRoute.v1`
- `AttachGrant.v1`
- `CredentialHandleRef.v1`
- `ExecutionEvent.v1`
- `ExecutionOutcome.v1`
- `ProcessExecutionIntent.v1`
- `JsonRpcExecutionIntent.v1`

`Jido.Harness.SessionControl.mapped_execution_contracts/0` publishes that list
for the facade layer.

`Jido.Harness.SessionControl.boundary_contract_keys/0` publishes the explicit
named boundary metadata groups carried through the facade layer:

- `descriptor`
- `route`
- `attach_grant`
- `replay`
- `approval`
- `callback`
- `identity`

## Provisional Minimal-Lane Note

The carrier names for:

- `ProcessExecutionIntent.v1`
- `JsonRpcExecutionIntent.v1`

are frozen in Wave 1, but their detailed family-facing payload semantics stay
provisional until Wave 3 prove-out.
