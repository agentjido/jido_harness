---
id: receipt.jido_harness_w20_codex_structured_output
status: accepted
release: 2.1.0-rc.2
release_identity: git_commit_containing_this_receipt
minimum_codex_cli: 0.144.6
authentication: cached_subscription
provider: codex
capability: structured_output
---

# W20 Codex Structured Output Acceptance Receipt

Jido.Harness `2.1.0-rc.2` is the accepted W20 consumer handoff. The exact
40-character commit containing this receipt and its release manifest is the
only compatible pin; consumer lockfiles and the parent adoption receipt record
that immutable value after this section commit exists.

## Deterministic acceptance

- `mix test`: 133 tests, 0 failures, 55 excluded.
- `mix quality`: passed formatting, compile warnings-as-errors, static analysis,
  type analysis, and documentation validation.
- Fake-CLI coverage exercises schema staging and cleanup, exact argv and
  environment isolation, result validation, cancellation, timeout, caller
  exit, process failure, incompatible CLI, missing authentication, concurrent
  runs, redaction, and the absence of API/provider/offline fallbacks.
- Admission accepts the governed 128-concept enum schema within a bounded
  aggregate ceiling of 256 values and rejects 257 values.
- Admission rejects schema combinators before provider execution after the
  compatible CLI rejected the attempted `anyOf` form during consumer smoke.

## Deliberate live smoke

After non-billable readiness reported installed, compatible, authenticated,
and `structured_output?: true`, one cached-subscription run completed with
Codex CLI `0.144.6`. It used the fixed ephemeral read-only profile and the
governed 128-concept enum shape, returned one schema-valid result under schema
id `w20.release.smoke.v1`, exposed no provider session id, and required no API
key. No prompt, model output, credential, private path, or token detail is
retained in this receipt.

## Disposition

Release candidate `2.1.0-rc.1` is superseded. Release candidate `2.1.0-rc.2`
is accepted for exact consumer pinning, subject to the consumer repositories'
own fail-closed integration acceptance.
