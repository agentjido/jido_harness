# Dependency policy

Jido.Harness v2 owns its supervision, process management, event journal, and
provider adapters. It deliberately has no dependency on `jido`, `jido_shell`,
Sprites, or Splode.

## Runtime dependencies

- `erlexec` supplies monitored subprocesses, stdin, PTY support, and process
  groups.
- `telemetry` is the direct observation boundary.
- `zoi` validates normalized public data.
- `jason` encodes journals and decodes CLI JSONL.
- Every built-in provider uses its official CLI through the harness process
  manager. Z.AI uses its officially supported Claude Code environment mapping.

Provider SDKs and generic subprocess wrappers are intentionally excluded. The
harness already owns option validation, supervision, process groups, timeouts,
cancellation, JSONL decoding, event normalization, and retention. Adding an SDK
that duplicates those responsibilities requires a demonstrated capability that
cannot be expressed through the provider CLI.

## Overrides and revisions

An override or source revision is acceptable only for a verified lifecycle or
protocol compatibility fix. Each provider change must pass:

1. fake-CLI long-runtime and cleanup contracts;
2. deterministic unit and fixture tests;
3. opt-in live smoke tests for affected providers;
4. `mix hex.build`, docs, static analysis, and the full unit suite.

Provider-specific JSONL mappers preserve unknown records as normalized
`provider_event` values. CLI arguments remain structured executable-plus-argv
data and are never interpolated into a shell command.
