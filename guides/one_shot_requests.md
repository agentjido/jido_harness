# One-shot requests

A one-shot request starts one supervised provider run and returns one terminal
`Jido.Harness.RunResult`.

## Blocking convenience

Use `Jido.Harness.run/3` when the caller can wait:

```elixir
{:ok, %Jido.Harness.RunResult{} = result} =
  Jido.Harness.run(:gemini, "Explain this repository",
    cwd: File.cwd!(),
    await_timeout: 600_000
  )
```

Accepted request forms are:

- a prompt string;
- a map or keyword list of normalized fields;
- a validated `Jido.Harness.RunRequest`.

The provider may be passed explicitly, included in the request, or obtained
from `config :jido_harness, default_provider: ...`.

## Normalized request fields

`RunRequest` defines the provider-neutral vocabulary:

- prompt, working directory, model, and provider resume ID;
- maximum turns and runtime/idle timeouts;
- system prompt, allowed/disallowed tools, additional directories, and MCP
  configuration;
- approval mode, sandbox mode, attachments, and reasoning effort;
- child environment, in-memory metadata, and nested `provider_options`.

The selected adapter declares which non-default fields it supports. Validation
fails before the CLI starts when a field or value cannot be represented.

```elixir
request = %{
  prompt: "Review the current branch",
  cwd: File.cwd!(),
  model: "provider-model-name",
  approval_mode: :prompt,
  sandbox_mode: :read_only,
  runtime_timeout_ms: 600_000,
  idle_timeout_ms: 120_000,
  metadata: %{request_origin: "review-button"}
}

Jido.Harness.run(:codex, request, await_timeout: 620_000)
```

## Runtime timeout and await timeout

These limits control different things:

- `runtime_timeout_ms` belongs to the request and limits provider execution.
- `idle_timeout_ms` limits a run that stops producing process activity.
- `await_timeout` limits only the blocking caller's wait.

An expired await returns `{:error, :timeout}` without cancelling the run. Use
the detached API when the caller needs the `run_id` before waiting.

## Interpret the result

A returned `RunResult` is terminal. Its `status` is one of `:completed`,
`:failed`, or `:cancelled`.

```elixir
case Jido.Harness.run(:claude, prompt, cwd: File.cwd!()) do
  {:ok, %Jido.Harness.RunResult{status: :completed} = result} ->
    IO.puts(result.text)

  {:ok, %Jido.Harness.RunResult{} = result} ->
    Logger.warning("provider ended with #{result.status}: #{inspect(result.error)}")

  {:error, %Jido.Harness.Error{} = error} ->
    Logger.error(Exception.message(error))
end
```

`text` is the bounded final text tail, `usage` is normalized when the provider
supplies it, and `events` contains the retained normalized event tail. When
`text_truncated?` is true, use run replay to consume the complete retained
sequence.

## Resume provider context

`provider_session_id` is the provider's resume token, not a harness resource
ID:

```elixir
Jido.Harness.run(:grok, %{
  prompt: "Continue with the next step",
  cwd: File.cwd!(),
  provider_session_id: prior_result.provider_session_id
})
```

Resume support is declared per provider. For a harness-owned multi-turn
conversation, prefer `Jido.Harness.Session`.

## When to move to detached runs

Use `Jido.Harness.Run.start/3` instead when you need to return a run ID
immediately, expose progress, survive caller exit, page through events, cancel
explicitly, or reattach from another process.
