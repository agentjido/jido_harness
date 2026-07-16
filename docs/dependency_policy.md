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
- Amp, Claude, Codex, and Gemini retain their existing SDK backends. Z.AI
  shares the Claude Agent SDK backend because Z.AI officially integrates GLM
  Coding Plan through Claude Code.

Gemini CLI SDK was retired before moving to `cli_subprocess_core` 0.2. The v2
package therefore pins the mutually compatible SDK generation on
`cli_subprocess_core` 0.1 so all four SDK-backed providers can coexist. Upgrade
these pins only as one reviewed set after recorded adapter fixtures, long-run
timeouts, cancellation, and subprocess cleanup all pass.

## Overrides and revisions

An override or source revision is acceptable only when it is needed for the seven
provider set to compile together or for a verified lifecycle fix. Each change
must preserve the provider SDK backend and pass:

1. fake-CLI long-runtime and cleanup contracts;
2. deterministic unit and fixture tests;
3. strict live smoke tests for all affected providers;
4. `mix hex.build`, docs, static analysis, and the full unit suite.

Do not replace an SDK-backed provider with a direct CLI implementation to avoid
an SDK compatibility issue.
