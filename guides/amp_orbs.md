# Control Amp Orbs

`Jido.Harness.Amp` starts and manages Amp threads that run in Amp-managed
Orbs. Amp keeps the thread, repository, Orb disk, and agent state. Harness does
not copy this state to the local host.

This API is separate from the Harness `:amp` provider:

- `Jido.Harness.run(:amp, ...)` runs Amp through the ACP adapter and keeps the
  process under Harness supervision.
- `Jido.Harness.Amp.start_orb/2` asks Amp to run the work remotely. It returns
  after Amp accepts the request.

Read the official [Orbs overview](https://ampcode.com/docs/orbs),
[Orb CLI guide](https://ampcode.com/docs/cli/spawning-orbs), and
[Amp SDK guide](https://ampcode.com/docs/sdk) before you enable remote work.

## Supported control path

Amp documents two product control paths: the Amp CLI and the TypeScript or
Python SDK. The SDK uses the CLI. Harness uses the CLI directly and does not
add a Node or Python SDK dependency.

The [Amp External API](https://ampcode.com/api/external) is for workspace data
and administration. It can list, read, and delete threads, but it cannot start
or continue an Orb thread. It also uses workspace application credentials,
not the personal access token used by the CLI. Amp directs product automation
to the CLI or SDK.

| Operation | Supported Amp interface | Harness function |
| --- | --- | --- |
| Start an Orb thread | `amp -ox` | `start_orb/2` |
| Continue and wake an Orb thread | `amp threads continue ... -ox` | `continue_orb/3` |
| List threads | `amp threads list --json` | `list_threads/1` |
| Export one thread | `amp threads export` | `export_thread/2` |
| Archive or restore a thread | `amp threads archive` | `archive_thread/2`, `unarchive_thread/2` |
| Delete a thread | `amp threads delete` | `delete_thread/2` |

Amp does not document a stable API to pause, stop, or kill an Orb. An Orb
pauses after the agent and user become idle. A new message wakes it. Archiving
a thread does not stop agent work that is already running. Deleting a thread
is permanent.

`amp top --stream-jsonl` reports active threads, but Amp marks its schema as
experimental. Harness does not make that schema part of its public API.
`list_threads/1` returns all Amp thread types, not only Orb threads.

## Configure a stateless host

Install the Amp CLI in the release image. Create an Amp access token in the
Amp security settings. Set it as a secret:

```sh
AMP_API_KEY=sgamp_...
```

The CLI rejects the short-lived token stored by `amp login` when that token is
passed through an environment variable. Use the access token that starts with
`sgamp_`.

The control API reads these variables on each call:

| Variable | Required | Use |
| --- | --- | --- |
| `AMP_API_KEY` | yes | Amp access token |
| `AMP_CLI_PATH` | no | Amp executable name or path; default is `amp` |
| `AMP_URL` | no | Amp service URL or required workspace domain |
| `JIDO_HARNESS_AMP_PROJECT` | no | Default Amp project, GitHub `owner/repo`, or repository URL |
| `JIDO_HARNESS_AMP_ORB_SIZE` | no | Default built-in size or self-hosted Orb type |
| `JIDO_HARNESS_AMP_ORB_PROVIDER` | no | Default Orb provider name, ID, or `builtin` |
| `JIDO_HARNESS_AMP_PROFILE` | no | Default Amp browser profile name or ID |
| `JIDO_HARNESS_AMP_MODE` | no | Default Amp mode |
| `JIDO_HARNESS_AMP_VISIBILITY` | no | `private`, `unlisted`, `workspace`, or `group` |
| `JIDO_HARNESS_AMP_FEATURES` | no | Comma-separated feature names, such as `fast` |
| `JIDO_HARNESS_AMP_LABELS` | no | Comma-separated labels |
| `JIDO_HARNESS_AMP_TIMEOUT_MS` | no | Short CLI command timeout; default is 60000 |
| `JIDO_HARNESS_AMP_MAX_OUTPUT_BYTES` | no | Maximum captured command output; default is 8 MiB |
| `JIDO_HARNESS_AMP_CWD` | no | Existing directory used to start the CLI |

Set the standard `XDG_CACHE_HOME`, `XDG_CONFIG_HOME`, and `XDG_DATA_HOME`
variables to writable, temporary directories in a read-only container. The
CLI can write short-lived local data there. Amp keeps the durable thread and
Orb state on its service, so these directories do not need a persistent
volume.

Check readiness without starting an Orb:

```elixir
{:ok, %Jido.Harness.Amp.Status{ready: true}} = Jido.Harness.Amp.status()
```

Readiness checks the CLI path, access-token format, and environment defaults.
It does not call Amp. Use `list_threads/1` for a read-only live authentication
check.

`Jido.Harness.status(:amp)` checks the separate ACP provider. Use
`Jido.Harness.Amp.status/0` for remote Orb control.

## Start and continue work

Environment values are defaults. Explicit call options take precedence.

```elixir
{:ok, orb} =
  Jido.Harness.Amp.start_orb(
    "Run the release checks and report each failure",
    project: "agentjido/jido_harness",
    orb_size: "a1.large",
    mode: "high",
    visibility: :private,
    labels: ["release", "managed-by-harness"]
  )

orb.thread_id
orb.url
```

The function runs the asynchronous `amp -ox` form. It returns the stable Amp
thread ID and URL. It does not wait for the agent result.

Harness passes `--no-archive-after-execute` for start and continue commands.
This keeps the thread available for later messages and event subscriptions.
Call `archive_thread/2` when the workflow is complete.

Send a later message with the ID or URL:

```elixir
{:ok, ^orb} =
  Jido.Harness.Amp.continue_orb(
    orb.thread_id,
    "The deployment finished. Verify it in production."
  )
```

The returned struct has the same thread identity. Amp wakes the Orb if it is
idle.

## Read and manage threads

```elixir
{:ok, threads} =
  Jido.Harness.Amp.list_threads(
    include_archived: true,
    limit: 50,
    offset: 0
  )

{:ok, thread} = Jido.Harness.Amp.export_thread(orb.thread_id)

:ok = Jido.Harness.Amp.archive_thread(orb.thread_id)
:ok = Jido.Harness.Amp.unarchive_thread(orb.thread_id)
```

Amp does not publish a stable schema for the CLI list and export JSON.
Harness decodes the JSON but keeps the provider field names as strings. This
prevents an undocumented Amp payload from becoming a Harness data contract.

Delete only after an explicit application decision:

```elixir
:ok = Jido.Harness.Amp.delete_thread(orb.thread_id)
```

Deletion removes the thread permanently.

## Map the API to HTTP

Harness does not add an HTTP server dependency. A Phoenix, Plug, or other host
application can use this route shape:

| HTTP route | Harness call |
| --- | --- |
| `POST /orbs` | `start_orb/2` |
| `POST /orbs/:thread_id/messages` | `continue_orb/3` |
| `GET /threads` | `list_threads/1` |
| `GET /threads/:thread_id` | `export_thread/2` |
| `POST /threads/:thread_id/archive` | `archive_thread/2` |
| `POST /threads/:thread_id/unarchive` | `unarchive_thread/2` |
| `DELETE /threads/:thread_id` | `delete_thread/2` |

Authenticate and rate-limit these routes. Do not accept an Amp token in the
request body. Keep it in the server environment.

Do not pass an untrusted local path to the `attachments` option. The Amp CLI
uploads that file. An HTTP service must first store an accepted upload in a
dedicated temporary directory and must pass only that verified path.

Amp does not document an idempotency key for `amp -ox`. A client retry can
start a second Orb thread. If one logical request must start only one thread,
put the idempotency record in the caller, queue, or database before it calls
the stateless Harness service.

The short local control process is supervised, has time and output limits, and
is removed after the command. A BEAM restart loses only that in-flight control
request. It does not lose an Amp thread that the service already accepted.

## Run the req_llm pull request example

The repository includes [standalone example scripts](https://github.com/agentjido/jido_harness/tree/release/v3/examples/amp_orbs)
for `agentjido/req_llm`. They validate a pull request with the GitHub CLI, start
an Orb through `Jido.Harness.Amp`, send follow-up messages, export the thread,
and archive it.

The examples use the repository-based Amp project selector
`agentjido/req_llm`. Amp resolves it to the existing project that maps to
`https://github.com/agentjido/req_llm`. The Amp display namespace can differ
from the GitHub repository owner.

Use Amp's [first-party GitHub webhooks](https://ampcode.com/docs/github#github-webhooks)
for pull request comments, reviews, and CI events. Amp verifies the GitHub
signatures and delivers events to the thread. A stateless Harness service does
not need to receive GitHub webhooks or keep a GitHub webhook secret.

Amp documents subscription creation through an agent in Amp or through Puck.
It does not document a matching CLI or External API endpoint. The example
scripts send the exact setup request to an Orb with `continue_orb/3`.

A new-Orb subscription for a GitHub organization repository must belong to an
Amp workspace project. Also select an Orb size that can complete the project
setup. The `req_llm` example uses `a1.medium` because `a1.small` reached its
memory limit while it compiled `llm_db`.

`req_llm` already has `.agents/setup` and `.agents/resume` on its default
branch. Amp can use them to prepare and wake the project Orb. Do not duplicate
dependency installation in the control service.
