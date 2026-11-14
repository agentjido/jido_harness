# Harness v3 compatibility result

Starting branch: `main`. Starting revision: `20fe00f7e954b8634b5ca73fc8cb7ee55230de24`.
The primary branch was retained to preserve local and concurrent work.
The delivery report names the exact published branch and commit.

Status: checked v3 package candidate; full Hancho compatibility is blocked.

## Boundary and branch reconciliation

Main `20fe00f7` is the ancestor of `release/v3` `771bacec`. The latter contains
three commits: a Signal-based rewrite using separate `jido_signal`, removal
of an Agent spike, and Amp Orb control. The candidate keeps main's Event and
ProcessEvent APIs and ACP-only execution. It restores the separate Amp Orb
feature, its examples, and its offline tests. The Amp process output reader
now reads ProcessEvent type/data instead of the old Signal payload.

The old Signal API and Signal journal format are not selected. The old branch
is preserved. Its users need an explicit source and stored-data migration.
See `guides/jido_v3.md` and the migration guide. No runtime core dependency was
added. A host-owned Signal carries an Event to a core Action/AgentServer route
in the new deterministic consumer fixture.

## Checks

- Final `ERL_FLAGS='+S 4:4' mix test`: 292 passed, 91 excluded; coverage 77.0%, above the unchanged 70% gate.
- `mix quality`: passed, including Dialyzer and Doctor. Required Amp function documentation was added; no quality setting changed.
- `integration/jido_v3`: `mix deps.get`, `mix deps.unlock --unused`, `mix test`: 1 passed.
- `mix hex.build`: passed. Explicit fixture paths exclude generated dependency and build trees.
- Separate read-only source review passed the Event/ProcessEvent conversion and the reconciliation boundary.
- Isolated Jidoka: 4 focused tests passed. Discovery is covered; paid/live ACP execution is not.

An earlier full test run had two undefined native-module subprocess failures
while parallel builds ran. Both native tests passed alone. The final full
suite then passed all 292 tests. Focused test invocations fail the package-wide
coverage gate by design; the final full run is the acceptance evidence.

## Hancho blocker and recovery

Hancho main was `aaa57926277ad1e709be3b7700e691aa5c8a8ca9`. The live checkout
was read-only. `/private/tmp/five-v3/hancho` used candidate Harness, consolidated
core `047bf746` in place of legacy Action, and Zoi 0.19. Temporary root graph
changes made Bedrock ownership explicit and resolved old telemetry/AWS locks.
`mix deps.get` succeeded after those graph repairs.

The command below then failed before tests ran:

```sh
ERL_FLAGS='+S 4:4' mix test test/hancho/harness_test.exs test/hancho/provider_contract_test.exs test/hancho/model_discovery_test.exs
```

The hard error is `lib/hancho/workflow/compiler.ex:341`: it matches removed
`%Zoi.Types.Default{}`. Its adapter fixtures also implement old run/cancel
callbacks. `lib/hancho/provider_contract.ex:113` calls removed direct-CLI
`build_argv/2` functions on Grok, Kimi, OpenCode, and Pi. These are consumer
migration requirements, not reasons to restore direct-CLI execution in the
ACP-only Harness runtime. No Hancho source was changed. Full Hancho tests are
untested until its owner migrates these APIs. This blocks a claim of full
consumer compatibility; it does not invalidate the passing Harness package
or core integration checks.

## Shared evidence and limits

Date: 2026-11-14. GitHub API checks confirmed consolidated core `release/v3`
at `047bf746330a2fbe7c3b25c045552e0303c97eaf`. Tests used Elixir 1.20.4,
OTP 29.1.2. Core owns Action, Signal, and AI modules. No separate legacy
core package is present in either new consumer fixture dependency tree.
No mandatory core runtime dependency was added to a standalone package.

The package sources and consumer fixtures were self-checked. A separate source
review checked the Harness reconciliation. No live model or paid provider
check ran. No live app home, checkpoint, or database was changed.

Jidoka started on `release/v3` at
`5b697d3d3a0f96bc7baf063687d4a98f31a0565a`, with local checkpoint work.
Its source was copied to `/private/tmp/five-v3/jidoka`. Only that copy's
manifest used paths to the four candidate libraries. Core remained pinned to
`047bf746`. The command below passed 4 tests with a temporary SQLite database:

```sh
MIX_TARGET=desktop ERL_FLAGS='+S 4:4' mix test test/jidoka/workspaces_test.exs test/jidoka/inference/detector_test.exs
```

The first two tests cover write/read/list/capture, mutation policy, storage
selection refusal, and close. The other two cover provider discovery and
failure normalization. They do not run a live Harness provider. The original
Jidoka checkout and its existing local changes were preserved.

## Release order

Publish the required consolidated core and shared dependencies first. ReqLLM
1.30.0 and Zoi 0.19.0 are already available. Release VFS before Shell, then
Workspace, then update and check Jidoka dependency pins. Character and Harness
can release independently after their shared dependencies are available.
Migrate Hancho before claiming it supports the new Harness candidate. No
registry publication, release, merge, or PR was part of this work.
