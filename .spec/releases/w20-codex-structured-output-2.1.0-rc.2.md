---
id: release.jido_harness_w20_codex_structured_output_2_1_0_rc_2
status: accepted_release_candidate
version: 2.1.0-rc.2
minimum_codex_cli: 0.144.6
capability: structured_output
provider: codex
authentication: cached_subscription
maximum_aggregate_enum_values: 256
---

# W20 Codex Structured Output Accepted Release Candidate

This candidate supersedes rc.1 and is the sole accepted consumer handoff for
W20 Phase 2. Consumers must pin the 40-character Git commit containing this
manifest; path, branch, floating-version, and direct OpenAI API dependencies
are incompatible.

The release supports finite and detached structured runs through the fixed
`:ephemeral_read_only` profile, private schema/workspace cleanup, cached Codex
subscription authentication, typed failures, and one schema-validated result.
It supports at most 256 aggregate enum members so the governed 128-concept
classification schema can retain exact concept membership plus bounded control
enums. Schema combinators are rejected during Harness admission because the
compatible Codex CLI cannot represent the attempted form exactly.

Consumers must verify version `2.1.0-rc.2`, minimum Codex CLI `0.144.6`, and
`structured_output?: true`; every unavailable or invalid result fails closed
without API, provider, offline, or session fallback.
