---
id: release.jido_harness_w20_codex_structured_output_2_1_0_rc_1
status: superseded
version: 2.1.0-rc.1
minimum_codex_cli: 0.144.6
capability: structured_output
provider: codex
authentication: cached_subscription
---

# W20 Codex Structured Output Release Candidate

This candidate was superseded by `2.1.0-rc.2` during integration because the
128-concept consumer schema requires a larger bounded aggregate enum ceiling.
It is not an accepted consumer pin.

This release candidate is the immutable consumer handoff for W20 Phase 2.
Consumers must pin the 40-character Git commit containing this manifest; path,
branch, floating-version, and direct OpenAI API dependencies are incompatible.

## Capability boundary

- finite `Jido.Harness.run` and detached `Jido.Harness.Run` execution only;
- one bounded JSON Schema object and caller-owned schema id;
- fixed `:ephemeral_read_only` isolation with private schema/workspace cleanup;
- Codex CLI cached subscription authentication only;
- one parsed and schema-validated result in `RunResult.structured_output`;
- non-billable readiness distinct from an explicit live smoke; and
- no session, resume, raw argv, credential, endpoint, API, SDK, provider, or
  offline fallback.

## Consumer migration

1. Pin the exact release-candidate commit and verify version
   `2.1.0-rc.1` at compile time.
2. Require `Jido.Harness.status(:codex)` to report installed, compatible,
   authenticated, and `structured_output?: true`.
3. Supply domain prompts and JSON Schemas through normalized request data.
4. Treat every non-completed result and absent `structured_output` value as a
   closed failure; do not repair or reroute.
5. Keep optional live subscription smokes behind an explicit operator opt-in.
