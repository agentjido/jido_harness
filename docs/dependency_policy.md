# Dependency and scope policy

Jido.Harness owns normalization, supervision, process management, event
journaling, retention, and provider adapters. Runtime dependencies must support
one of those boundaries without duplicating the package's core responsibility.

## Runtime dependencies

| Dependency | Purpose |
| --- | --- |
| `erlexec` | monitored subprocesses, stdin, PTY, process groups, and signals |
| `telemetry` | direct runtime observation boundary |
| `zoi` | validation and construction of normalized public structs |
| `jason` | provider JSON/JSONL decoding and journal encoding |

Every built-in provider uses its official CLI through the Jido.Harness process
manager. Z.AI uses its officially supported Claude Code environment mapping.

## Explicit exclusions

The runtime does not depend on:

- provider SDKs;
- generic subprocess wrappers;
- `jido` or `jido_shell`;
- Sprites or Splode.

Provider SDKs and subprocess wrappers would duplicate responsibilities already
owned here: option validation, supervision, process groups, timeouts,
cancellation, JSONL mapping, normalized events, and retention. Adding one
requires a demonstrated capability that the provider's official headless CLI
cannot express.

## Product boundary

Jido.Harness is not a provider router, durable job system, workspace
provisioner, retry engine, TUI automation system, or general shell library.
Those concerns belong outside the package and should integrate through stable
harness IDs and normalized results.

## Overrides and revisions

An override or source revision is acceptable only for a verified lifecycle or
protocol compatibility fix. Each provider-related dependency change must pass:

1. fake-CLI long-runtime and cleanup contracts;
2. deterministic mapper and fixture tests;
3. opt-in live tests for affected providers;
4. documentation, package build, static analysis, and the full unit suite.

Provider-specific records without a canonical mapping remain
`:provider_event` values. CLI arguments remain structured executable-plus-argv
data and are never interpolated into a shell command.
