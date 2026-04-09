# Jido.Harness

Normalized Elixir contract layer for CLI AI coding agents and Session Control
runtimes.

`Jido.Harness` now supports two explicit surfaces:

- legacy provider adapters registered under `:providers`
- Session Control runtime drivers registered under `:runtime_drivers`

It also now aligns its lower-boundary vocabulary with the frozen packet and the
Wave 5 durable session-carriage vocabulary:

- `BoundarySessionDescriptor.v1`
- `ExecutionRoute.v1`
- `AttachGrant.v1`
- `CredentialHandleRef.v1`
- `ExecutionEvent.v1`
- `ExecutionOutcome.v1`
- `ProcessExecutionIntent.v1`
- `JsonRpcExecutionIntent.v1`

Harness maps or carries those contracts. It does not re-export raw
`execution_plane/*` packages as its public API.

## Installation

Add `jido_harness` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jido_harness, "~> 0.1.0"}
  ]
end
```

For active local development beside sibling checkouts, `jido_harness` can also
be consumed from a relative path:

```elixir
{:jido_harness, path: "../jido_harness"}
```

Its runtime dependencies now follow one stable policy:

- prefer a sibling-relative path for `jido_shell` when that checkout exists
- otherwise fall back to pinned git refs
- use a pinned git ref for `sprites`, with an optional sibling checkout if one
  exists locally

Floating branch dependencies are no longer the default.

## Usage

### Legacy Adapter World

```elixir
# Optional: configure provider adapter modules explicitly
config :jido_harness, :providers, %{
  codex: Jido.Codex.Adapter,
  gemini: Jido.Gemini.Adapter
}

# Optional: set a default provider adapter
config :jido_harness, :default_provider, :codex

# Run with explicit provider
{:ok, events} = Jido.Harness.run(:codex, "fix the bug", cwd: "/my/project")

# Or run through the default provider
{:ok, events} = Jido.Harness.run("fix the bug", cwd: "/my/project")
```

### Session Control Runtime-Driver World

```elixir
config :jido_harness, :runtime_drivers, %{
  jido_session: Jido.Session.HarnessDriver,
  asm: Jido.Integration.V2.RuntimeAsmBridge.HarnessDriver
}

config :jido_harness, :default_runtime_driver, :jido_session

request = Jido.Harness.RunRequest.new!(%{prompt: "fix the bug", metadata: %{}})

{:ok, session} =
  Jido.Harness.start_session(
    :jido_session,
    session_id: "session-1",
    provider: :jido_session
  )

{:ok, run, events} = Jido.Harness.stream_run(session, request, run_id: "run-1")
{:ok, result} = Jido.Harness.run_result(session, request, run_id: "run-2")
```

## What It Wraps

Legacy adapter resolution can resolve providers from:
- explicit app config (`config :jido_harness, :providers, %{...}`)
- runtime auto-discovery of known module candidates for:
  - `:codex`
  - `:amp`
  - `:claude`
  - `:gemini`
  - `:opencode`

Auto-discovery is non-invasive: modules are used only if they are loaded and expose a supported run API.

## Public Facade

Legacy adapter functions:

```elixir
Jido.Harness.providers()
Jido.Harness.default_provider()

Jido.Harness.run(:codex, "prompt", cwd: "/repo")
Jido.Harness.run("prompt", cwd: "/repo")

request = Jido.Harness.RunRequest.new!(%{prompt: "prompt"})
Jido.Harness.run_request(:codex, request, transport: :exec)
Jido.Harness.run_request(request)

Jido.Harness.capabilities(:codex)
Jido.Harness.cancel(:codex, "session_id")
```

Session Control runtime-driver functions:

```elixir
Jido.Harness.runtime_drivers()
Jido.Harness.default_runtime_driver()
Jido.Harness.runtime_descriptor(:jido_session)

{:ok, session} = Jido.Harness.start_session(:jido_session, provider: :jido_session)
{:ok, run, events} = Jido.Harness.stream_run(session, request)
{:ok, result} = Jido.Harness.run_result(session, request)
{:ok, status} = Jido.Harness.session_status(session)
:ok = Jido.Harness.approve(session, "approval-1", :allow)
{:ok, cost} = Jido.Harness.cost(session)
:ok = Jido.Harness.cancel_run(session, run)
:ok = Jido.Harness.stop_session(session)
```

`Jido.Harness.run_result/3` is the public facade for a runtime driver's
optional `run/3` callback. `Jido.Harness.RuntimeDriver` also defines optional
`subscribe/2` and `resume/3` callbacks; drivers advertise those capabilities
through `RuntimeDescriptor.subscribe?` and `RuntimeDescriptor.resume?`.

For boundary-backed execution, runtimes carry live boundary descriptors or
attach metadata under `metadata["boundary"]`. The named Wave 5 subcontracts
inside that namespace are `descriptor`, `route`, `attach_grant`, `replay`,
`approval`, `callback`, and `identity`. Harness keeps that carriage
runtime-neutral and does not own sandbox policy, target selection, or boundary
backend semantics.

The current family-facing carrier details for `ProcessExecutionIntent.v1` and
`JsonRpcExecutionIntent.v1` remain provisional until Wave 3 prove-out. Wave 1
freezes the names, ownership, and carriage rules only.

## Documentation Menu

- `README.md` - install, public facade, and runtime-driver framing
- `docs/execution_plane_alignment.md` - frozen lower-boundary packet and
  carriage rules
- `docs/telemetry.md` - signal and telemetry conventions
- `docs/dependency_policy.md` - dependency posture and update rules

## Documentation

Full documentation is available at [https://hexdocs.pm/jido_harness](https://hexdocs.pm/jido_harness).

## Package Purpose

`jido_harness` is the provider-neutral contract layer shared by legacy CLI
adapters and Session Control runtime drivers. It owns the public IR, runtime
driver behaviour, and generic runtime bootstrap/preflight helpers.

It is intentionally not a transport registry. Runtime drivers may carry
`execution_surface` and `execution_environment` through to deeper layers, but
`jido_harness` itself does not enumerate or normalize transport families.

The canonical lower-boundary packet vocabulary is exposed as metadata and
mapped IR through `Jido.Harness.SessionControl.mapped_execution_contracts/0`,
not as a wholesale re-export of raw lower packages.

## Testing Paths

- Unit/runtime tests: `mix test`
- Full quality gate: `mix quality`
- Registry/runtime diagnostics: `Jido.Harness.Registry.diagnostics/0` in `iex -S mix`
