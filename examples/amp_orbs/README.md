# Use Harness with req_llm Orbs

These scripts use `Jido.Harness.Amp` to control Amp Orbs for pull requests in
`agentjido/req_llm`. Each entry script is an Elixir script. It installs the
local Harness checkout with `Mix.install/1`.

The scripts do not run an HTTP server. Amp keeps each thread and Orb. The local
process only sends short control commands.

## 1. Connect Amp to GitHub

Open **Amp Settings → Integrations & MCP**. Connect the GitHub account that can
write to `agentjido/req_llm`. Install the Amp GitHub App on the `agentjido`
organization and include the `req_llm` repository.

Amp uses this connection to clone the repository, use `gh`, push branches, and
read CI. The Orb does not need a long-lived GitHub token in an environment
variable. See the official [GitHub and Git guide](https://ampcode.com/docs/github).

The Amp project is already present:

```text
Amp selector:      agentjido/req_llm
GitHub repository: agentjido/req_llm
Example Orb size:  a1.medium
Base branch:       main
```

Amp resolves this repository selector to the existing project. The Amp project
page can show a different personal or workspace namespace.

The `req_llm` repository already has `.agents/setup` and `.agents/resume`.
`.agents/setup` installs OTP 29.0.3, Elixir 1.20.2, Hex, Rebar, and Mix
dependencies. `.agents/resume` checks the BEAM tools after each Orb wake.

You can inspect the project without starting work:

```sh
amp projects get agentjido/req_llm --json
amp projects snapshots list agentjido/req_llm
```

## 2. Set the control environment

Create an Amp access token in the Amp security settings. Use a token that
starts with `sgamp_`. The short token from `amp login` is not a stateless
service credential.

Copy the tracked template to the ignored root `.env` file. Then add your access
token to the first line:

```sh
cp .env.example .env
```

```text
AMP_API_KEY=sgamp_your_access_token
```

The example scripts load this file automatically. Shell environment values
take precedence over values in `.env`. Do not commit the real token.

The file contains these non-secret defaults:

```sh
JIDO_HARNESS_AMP_PROJECT=agentjido/req_llm
JIDO_HARNESS_AMP_ORB_SIZE=a1.medium
JIDO_HARNESS_AMP_MODE=high
JIDO_HARNESS_AMP_VISIBILITY=private
REQ_LLM_GITHUB_REPO=agentjido/req_llm
```

The scripts supply these non-secret defaults when you omit them. Only
`AMP_API_KEY` is required. `start_pr.exs` also uses your local `gh` command to
read current pull request metadata.

Check the setup:

```sh
elixir examples/amp_orbs/status.exs
```

Continue only when the JSON has `"ready": true`.

`status.exs` checks the token format. Confirm the token with one read-only live
request:

```sh
elixir examples/amp_orbs/threads.exs --limit 1
```

The examples use `a1.medium`. A live `a1.small` setup reached its memory limit
while it compiled `llm_db`. Amp's system log recorded an OOM kill. Set the
project default to `a1.medium` before you enable a PR spawner. A spawner uses
the project default for each new Orb.

## 3. Start one review Orb

Start with a review-only task:

```sh
elixir examples/amp_orbs/start_pr.exs 123
```

Add a focused instruction after the pull request number:

```sh
elixir examples/amp_orbs/start_pr.exs 123 \
  "Focus on provider option translation and missing regression tests."
```

The script reads the live pull request with `gh`. It then starts one private
Orb in `agentjido/req_llm`. The JSON result contains a stable `T-...`
thread ID and an Amp URL.

Review mode can run safe tests and apply the review-state label required by
the `req_llm` `AGENTS.md`. It cannot edit source files, commit, push, or merge.

Use `--intent work` only when the Orb can change and push the pull request
branch:

```sh
elixir examples/amp_orbs/start_pr.exs --intent work 123 \
  "Fix the blocking findings, run mix quality, and push the branch."
```

Work mode still forbids a force-push and merge.

Do not run `start_pr.exs` again to send a new instruction. Amp does not supply
an idempotency key for Orb creation. A retry can create a second Orb. Continue
the first thread instead:

```sh
elixir examples/amp_orbs/continue.exs T-THREAD \
  "Implement the first finding. You can edit, test, commit, and push this PR branch. Do not merge or force-push."
```

## 4. Follow reviews and CI

Amp has a first-party GitHub event path:

```text
GitHub App events -> Amp event subscription -> existing Orb thread
Operator request  -> Harness and Amp CLI    -> existing Orb thread
```

Ask the same thread to follow PR comments, reviews, and the exact head commit
for 24 hours:

```sh
elixir examples/amp_orbs/follow_pr.exs T-THREAD 123
```

Use a third argument to change the number of hours:

```sh
elixir examples/amp_orbs/follow_pr.exs T-THREAD 123 72
```

Amp does not document a CLI or External API command that creates this
subscription. `follow_pr.exs` continues the Orb with a precise request. The
agent then uses Amp's subscription tool. Amp documents the same flow for Amp
and Puck.

Amp verifies the GitHub signatures. You do not need a GitHub webhook URL, a
webhook secret, or a Fly webhook receiver. An event does not grant permission
to push, merge, or deploy. The script puts this rule in its prompt.

Open **Amp Settings → Integrations & MCP → GitHub → Event Subscriptions** to
inspect, pause, resume, or delete subscriptions. Archiving a receiving thread
stops deliveries to that thread.

## 5. Optionally spawn an Orb for each new PR

Amp requires an Amp workspace-owned subscription for a GitHub organization
repository. A personal project that maps to `agentjido/req_llm` is not enough.
Create or select an Amp workspace, then move or create the project in that
workspace. The desired project selector is `agentjido/req_llm`.

The spawner script is a dry run unless you add `--apply`. The default starts a
High-mode review Orb for every newly opened pull request:

```sh
elixir examples/amp_orbs/setup_pr_spawner.exs
elixir examples/amp_orbs/setup_pr_spawner.exs --apply
```

This asks Amp to create a first-party spawner. It starts one new Orb for each
new `req_llm` pull request. Each Orb does a review-only triage pass. It reads
the base-branch instructions, inspects the diff and CI, reports prioritized
findings, and sets the required review-state label. It cannot edit, commit,
push, merge, deploy, or post a GitHub review or comment during triage.

You can restrict a new spawner to pull requests that have a label when they
open:

```sh
elixir examples/amp_orbs/setup_pr_spawner.exs --label amp --apply
```

Adding the label after the pull request opens does not trigger that filtered
spawner.

The setup script does not create a generic Amp plugin or a repository webhook.
Manage the spawner in the same Event Subscriptions page. A spawner continues
after you archive its setup thread. Pause or delete the spawner when you no
longer want new Orbs.

## 6. Inspect and close threads

```sh
elixir examples/amp_orbs/threads.exs --limit 20
elixir examples/amp_orbs/show.exs T-THREAD
elixir examples/amp_orbs/archive.exs T-THREAD
elixir examples/amp_orbs/archive.exs --restore T-THREAD
```

`show.exs` prints the full thread export. Treat that output as sensitive. The
examples do not include a delete script because deletion is permanent.

## Use the same split on Fly

Use Fly only for your stateless Harness control API. Install the Amp CLI in the
image. Set `AMP_API_KEY` and the `JIDO_HARNESS_AMP_*` values as Fly secrets or
environment variables. Give `XDG_CACHE_HOME`, `XDG_CONFIG_HOME`, and
`XDG_DATA_HOME` writable temporary paths.

Let the Amp GitHub App receive GitHub events. Do not send those events through
the Fly machine. This split keeps webhook signature checks, event storage, and
Orb wake-up inside Amp. The Fly service can expose authenticated routes that
call `start_orb/2`, `continue_orb/3`, `list_threads/1`, and `export_thread/2`.
