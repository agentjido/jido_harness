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

## Frozen Wave 1 Vocabulary

The canonical lower-boundary contract names that must remain consistent with
the Wave 1 packet are:

- `BoundarySessionDescriptor.v1`
- `AttachGrant.v1`
- `ExecutionEvent.v1`
- `ExecutionOutcome.v1`
- `ProcessExecutionIntent.v1`
- `JsonRpcExecutionIntent.v1`

`Jido.Harness.SessionControl.mapped_execution_contracts/0` publishes that list
for the facade layer.

## Provisional Minimal-Lane Note

The carrier names for:

- `ProcessExecutionIntent.v1`
- `JsonRpcExecutionIntent.v1`

are frozen in Wave 1, but their detailed family-facing payload semantics stay
provisional until Wave 3 prove-out.
