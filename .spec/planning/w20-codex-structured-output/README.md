---
id: plan.jido_harness_w20_codex_structured_output
status: completed
intent: feature
parent_plan: plan.w20_live_hr_company_brain_demonstration
parent_phase: plan.w20_phase_02_codex_subscription_runtime
frozen_default_sha: e41fc1651282469f2db4219a48d9f7feef1b0dbc
authority_decision: docs/decisions/structured-output-schema-isolation.md
---

# W20 Codex Structured Output Child Plan

This child plan delivers the generic schema-constrained finite-run capability
required by W20 through Codex cached subscription authentication. It owns no HR
prompt, provider-routing policy, classification meaning, answer policy, or
direct OpenAI API path.

- [x] 1 Phase - Release schema-constrained Codex finite execution.

  This phase maps Parent Phase 2 into one provider-owned release and remains
  authorized by the W20 Phase 1 merged-default adoption receipt.

  - [x] 1.1 Section - Implement normalized structured-output requests and private schema lifecycle.

    This section adds provider-neutral schema admission and harness-owned
    staging without changing existing unstructured runs or sessions.

    - [x] 1.1.1 Task {#jido-w20-p01-s01-schema} [parent: w20-p02-s01-structured-output] - Add the bounded structured-output request contract.

      This task makes schema data and isolation explicit normalized inputs and
      rejects raw provider arguments, schema paths, credentials, and sessions.

      - [x] 1.1.1.1 Subtask {#jido-w20-1-1-1-1} - Add request schema, capability declarations, limits, validation, and typed unsupported-option errors.
      - [x] 1.1.1.2 Subtask {#jido-w20-1-1-1-2} - Add owner-only schema directory/file creation, deterministic serialization, redaction, and cleanup across every terminal path.

  - [x] 1.2 Section - Implement Codex argv mapping, isolation, and result validation.

    This section translates the admitted request to one reviewed Codex CLI
    execution while preserving actual enforced isolation and subscription auth.

    - [x] 1.2.1 Task {#jido-w20-p01-s02-codex} [parent: w20-p02-s01-structured-output] [after: {#jido-w20-p01-s01-schema}] - Implement the Codex structured-output adapter path.

      This task uses executable-plus-argv construction and fails closed when
      the installed Codex version cannot represent the exact contract.

      - [x] 1.2.1.1 Subtask {#jido-w20-1-2-1-1} - Map schema and isolation options, prohibit resume/session reuse, and preserve cached CLI authentication without reading credentials.
      - [x] 1.2.1.2 Subtask {#jido-w20-1-2-1-2} - Extract one terminal result under bounds, parse once, validate the schema, and normalize missing, duplicate, malformed, truncated, or invalid output.

    - [x] 1.2.2 Task {#jido-w20-p01-s02-safety} [parent: w20-p02-s02-isolation] [after: {#jido-w20-p01-s02-codex}] - Prove isolation, cancellation, and redaction behavior.

      This task ensures concurrent and failed runs cannot retain or disclose
      another run's schema, workspace, environment, output, or terminal state.

      - [x] 1.2.2.1 Subtask {#jido-w20-1-2-2-1} - Cover start failure, caller exit, timeout, cancellation, provider crash, cleanup failure, and concurrent-run isolation.
      - [x] 1.2.2.2 Subtask {#jido-w20-1-2-2-2} - Cover absent authentication and incompatible CLI behavior with no API, provider, or offline fallback.

  - [x] 1.3 Section - Freeze release compatibility and consumer handoff.

    This section publishes one immutable capability identity for downstream
    consumers without embedding any consumer prompt or domain schema.

    - [x] 1.3.1 Task {#jido-w20-p01-s03-release} [parent: w20-p02-s03-release-pin] [after: {#jido-w20-p01-s02-safety}] - Release and document the compatible structured-output seam.

      This task separates non-billable readiness, optional live smoke, package
      release identity, Codex CLI compatibility, and consumer pin evidence.

      - [x] 1.3.1.1 Subtask {#jido-w20-1-3-1-1} - Update adapter/security/provider documentation and capability discovery with exact compatibility and failure semantics.
      - [x] 1.3.1.2 Subtask {#jido-w20-1-3-1-2} - Publish one immutable release for Company Brain and MetaGraph Search to pin exactly.

  - [x] 1.4 Section - Integration Tests and provider release acceptance.

    This final section proves the complete provider contract and is the only
    local section permitted to make the release eligible for W20 consumers.

    - [x] 1.4.1 Task {#jido-w20-p01-integration} [parent: w20-p02-integration] [after: {#jido-w20-p01-s03-release}] - Run exact-default provider integration and publish the release receipt.

      This task combines deterministic fake-CLI coverage with one deliberate
      cached-subscription smoke after non-billable readiness succeeds.

      - [x] 1.4.1.1 Subtask {#jido-w20-1-4-1-1} - Run formatting, unit, property, lifecycle, concurrency, cancellation, redaction, compatibility, and full quality gates.
      - [x] 1.4.1.2 Subtask {#jido-w20-1-4-1-2} - Run one opt-in schema-valid Codex smoke, record only redacted identity evidence, and publish the immutable provider receipt.

    Planned completion evidence: `receipt.jido_harness_w20_codex_structured_output`.

## Current frontier

Phase 1 is complete. Jido.Harness `2.1.0-rc.2` is accepted for exact consumer
pinning through `receipt.jido_harness_w20_codex_structured_output`.
