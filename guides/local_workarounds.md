# Local workarounds

These tools require a source checkout of this repository. They provide local
fixes for Codex isolation and native process startup.
They do not require an upstream PR or release. Keep the patch manifest and test
records when you change a dependency.

## Writable Codex tasks

Use the installed Codex CLI for finite isolation tasks:

```sh
python3 scripts/local_workarounds/codex_isolated.py --cwd /path/to/fixture \
  --model YOUR_MODEL --effort xhigh "Update the fixture"
```

The helper requires `codex exec --ephemeral` and `--ignore-user-config`. It
checks that the selected CLI reports both flags before execution. It uses the
`workspace-write` sandbox, disables interactive approvals, and emits the CLI's
JSON events. It keeps the existing authentication environment and home. It does
not copy credentials or create a temporary Codex home. Codex owns login state
and token refresh.

Workspace instructions remain available. The helper does not pass
`--ignore-rules` or bypass the sandbox. The installed CLI defines the scope of
`--ignore-user-config`; the helper does not remove other files from the home.
Resume is unavailable because the task is ephemeral.
Use a model supported by the selected Codex CLI. The helper passes the model
name unchanged. Omit `--model` to use the CLI default.
With task text, the helper closes stdin so a supervised pipe cannot delay
startup. With `-` as the task argument, it reads task text from stdin.

This helper runs a CLI task. It does not implement ACP sessions or return a
Harness `RunResult`. The pinned Codex ACP package still rejects requests for
the new isolation controls. For native process supervision and event replay,
use the helper through the Harness process API:

```elixir
{:ok, process_id} = Jido.Harness.Process.start(%{
  executable: System.find_executable("python3"),
  argv: [
    Path.expand("scripts/local_workarounds/codex_isolated.py"),
    "--cwd", "/path/to/fixture",
    "Update the fixture"
  ],
  cwd: "/path/to/fixture"
})

{:ok, info} = Jido.Harness.Process.await(process_id, 120_000)
{:ok, events} = Jido.Harness.Process.replay(process_id)
```

For one live check through this process API, run
`mix run scripts/local_workarounds/check_local_codex.exs`. This uses the CLI
default model and creates a temporary fixture. The model must write two files
and follow the fixture's instructions. The check records the helper hash and checks that no
session file contains the returned thread ID. This check sends a billable task.

## Native process startup

Apply the local correction after fetching dependencies:

```sh
mix deps.get
python3 scripts/local_workarounds/apply_local_erlexec.py
python3 scripts/local_workarounds/check_local_erlexec.py
mix run scripts/local_workarounds/local_process_soak.exs
```

The correction is pinned to erlexec 2.5.0. The manifest records the original
source hash and the patched source hash. The setup command refuses other
source contents. It can run again when the patch is already present. It
rebuilds the port and records its executable hash in
`.local-workarounds/erlexec-build.json`.

The child and parent both set the process group. If the child's call fails,
the patch checks the actual group. It continues only when the group is already
correct. A wrong group still causes a startup error. The patch adds no retry.
The observed error does not prove the cause of the underlying macOS syscall
failure or the cause of the older Codex failure.

The regression checks use separate Erlang VMs. A pipe reports completion of
the parent assignment before the test forces a child error. The checks do not
replace the application's registered server or depend on a fixed delay. The
soak check runs 100 timed-out processes and 800 native echo processes, without
retries.

The native test fixtures are in `test/support/fixtures/process_groups/`.
The Codex helper tests are in `test/scripts/`. Run them without a live provider:

```sh
python3 -m unittest discover -s test/scripts -v
```

Run these checks after an upgrade. If a dependency fetch replaces the source,
apply the patch again before local runs. Review a new dependency version before
changing the manifest. The package dependency declaration remains unchanged;
this is a local build correction.
