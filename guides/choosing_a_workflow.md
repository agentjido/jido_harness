# Choosing a workflow

Choose the smallest lifecycle API that matches the work you need to control.

| Requirement | API | Why |
| --- | --- | --- |
| Send one request and wait | `Jido.Harness.run/3` | Minimal blocking convenience |
| Return immediately or reattach later | `Jido.Harness.Run` | Stable run identity and full lifecycle control |
| Preserve conversation context across turns | `Jido.Harness.Session` | Harness-owned session and turn queue |
| Run an arbitrary local executable | `Jido.Harness.Process` | Structured process ownership without a shell |

## Blocking one-shot request

Use `Jido.Harness.run/3` when the caller can wait and does not need the run ID
before completion:

```elixir
{:ok, result} =
  Jido.Harness.run(:claude, "Summarize this repository",
    cwd: File.cwd!(),
    await_timeout: 600_000
  )
```

`await_timeout` bounds only this call. If it expires, the supervised run keeps
going and can be found through `Jido.Harness.Run.list/1`.

## Detached finite run

Use `Jido.Harness.Run` when a web request, job process, or stream consumer may
end before the provider does:

```elixir
{:ok, run_id} = Jido.Harness.Run.start(:codex, prompt, cwd: File.cwd!())
{:ok, info} = Jido.Harness.Run.info(run_id)
{:ok, result} = Jido.Harness.Run.await(run_id, 600_000)
```

The `run_id` is the lookup and lifecycle key. A provider's own resumable thread
or session token is held separately as `provider_session_id`.

## Interactive session

Use `Jido.Harness.Session` when later input should continue the same provider
context:

```elixir
{:ok, session_id} = Jido.Harness.Session.start(:pi, %{cwd: File.cwd!()})
{:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "Inspect the project")
{:ok, turn} = Jido.Harness.Session.await(session_id, turn_id, 600_000)
```

Session transports vary. Some maintain one native persistent protocol process;
others provide managed multi-turn behavior by resuming a provider session in a
new supervised process for each turn. Inspect the selected transport's
capabilities before depending on steering, approvals, attachments, or dynamic
configuration.

## Managed local process

Use `Jido.Harness.Process` for a local executable that is not a provider run:

```elixir
{:ok, process_id} =
  Jido.Harness.Process.start(%{
    executable: "git",
    argv: ["status", "--short"],
    cwd: File.cwd!(),
    stdin: false
  })

{:ok, info} = Jido.Harness.Process.await(process_id, 30_000)
```

This API exposes the subprocess capability used internally by adapters while
keeping direct processes distinct from provider runs.

## A resource is not a provider session

Keep these identifiers separate:

| ID | Meaning |
| --- | --- |
| `run_id` | One finite harness execution |
| `session_id` | One interactive harness resource |
| `turn_id` | One accepted turn inside a session |
| `process_id` | One managed OS process |
| `provider_session_id` | A provider-owned resume token |

Harness IDs control Jido.Harness resources. A provider session ID is request
data used to resume provider context and cannot look up a harness resource.
