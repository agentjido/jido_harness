# Adapter Contract

This checklist defines the stable surface that `jido_harness` expects from every adapter package in the current ecosystem phase.

## Required Callbacks

Every adapter must implement:

- `id/0`
- `capabilities/0`
- `run/2`
- `runtime_contract/0`

`cancel/1` is optional, but only optional when the adapter reports `cancellation?: false`.

## `id/0`

- returns the provider atom used by the harness registry
- must match `runtime_contract().provider`

Examples:

- `:codex`
- `:amp`
- `:claude`
- `:gemini`
- `:opencode`

## `capabilities/0`

Adapters must return `%Jido.Harness.Capabilities{}` with explicit booleans for all flags.

Current flag meanings:

- `streaming?`: `run/2` emits incremental events instead of only terminal output
- `tool_calls?`: adapter emits normalized `:tool_call` events
- `tool_results?`: adapter emits normalized `:tool_result` events
- `thinking?`: adapter emits normalized thinking/reasoning events
- `resume?`: adapter can resume a previous session/thread
- `usage?`: adapter emits canonical `:usage` events
- `file_changes?`: adapter emits normalized file-change events
- `cancellation?`: adapter exposes `cancel/1` for active sessions

These flags are declarative contract metadata. They are not marketing claims. If a capability is incomplete or conditional, keep it `false` until the emitted behavior is stable.

## `run/2`

- accepts `%Jido.Harness.RunRequest{}`
- returns `{:ok, enumerable}` or `{:error, reason}`
- emits `%Jido.Harness.Event{}` values only
- uses provider-specific metadata from `request.metadata`
- returns structured validation/config/execution errors on adapter-facing failures

## `runtime_contract/0`

Adapters must return `%Jido.Harness.RuntimeContract{}` with:

- provider id
- required host env vars
- forwarded/injected runtime env vars
- required runtime tools
- compatibility probes
- install steps
- auth bootstrap steps
- `triage_command_template`
- `coding_command_template`
- `success_markers`

## Command Template Semantics

Templates must be non-empty and use one of the canonical placeholders:

- `{{prompt}}` for inline prompt substitution
- `{{prompt_file}}` for prompt-file substitution

The harness runtime layer expands these placeholders when building commands. Adapters should not invent package-specific placeholder names.

## Success Marker Semantics

`success_markers` must be a non-empty list of maps with string keys.

These markers define what the harness runtime should treat as terminal success when evaluating streamed or runtime-mediated execution. They should match real adapter output, not best-effort guesses.

## Error Shape

Adapter-facing validation/config/execution failures should be returned as structured error structs, not raw tuples, whenever the adapter is rejecting input or surfacing a known adapter/runtime failure mode.

Internal SDK/library tuples may still exist below the adapter boundary, but `run/2` and related public adapter entry points should normalize them before they escape.
