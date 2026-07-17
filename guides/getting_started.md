# Getting started

This guide installs Jido.Harness, verifies one provider without sending a
prompt, and makes one live normalized request.

## Add the dependency

```elixir
def deps do
  [
    {:jido_harness, "~> 2.0"}
  ]
end
```

Fetch dependencies and compile the application:

```console
mix deps.get
mix compile
```

Jido.Harness starts its registries, dynamic supervisors, task supervisors, and
retention worker with the application. The nine built-in adapters require no
registration.

## Install and authenticate a provider CLI

Provider CLIs remain responsible for their own authentication. Install and log
in to at least one supported CLI, then ask Jido.Harness for a non-billable
status report:

```console
mix jido_harness.check --providers codex
```

The report distinguishes:

- whether the executable is installed;
- whether its version is compatible;
- whether authentication is known, unknown, or unavailable;
- whether the adapter is ready to attempt a smoke request.

Cached-login CLIs may report authentication as `unknown`. This means status
inspection cannot prove the login state; it does not mean authentication
failed.

Use `--strict` in setup scripts when an unavailable provider must fail the
command:

```console
mix jido_harness.check --providers codex --strict
```

Use `--json` for machine-readable output.

## Make one optional CLI smoke request

```console
mix jido_harness.chat codex
```

This sends `Reply with exactly: ready` through one provider and one finite
harness run. It may consume paid API or subscription usage. It is deliberately
not an interactive chat loop.

## Make the same request from Elixir

```elixir
alias Jido.Harness.RunResult

{:ok, %RunResult{status: :completed} = result} =
  Jido.Harness.run(:codex, "Reply with exactly: harness-ready",
    cwd: File.cwd!(),
    await_timeout: 300_000
  )

IO.puts(result.text)
```

The explicit provider form works without application configuration. To omit
the provider from requests, configure a default:

```elixir
config :jido_harness, default_provider: :codex
```

Then:

```elixir
{:ok, result} = Jido.Harness.run("Reply with exactly: harness-ready")
```

## Set provider defaults

Provider configuration can supply request or session defaults without changing
call sites:

```elixir
config :jido_harness,
  default_provider: :codex,
  provider_config: %{
    codex: %{
      request_defaults: %{
        sandbox_mode: :workspace_write,
        approval_mode: :prompt
      },
      session_defaults: %{
        sandbox_mode: :workspace_write
      }
    }
  }
```

An individual request overrides configured defaults. Provider-specific options
belong inside `provider_options` and are validated against the selected
adapter's declaration.

## Handle unsuccessful terminal results

`{:ok, result}` means the harness successfully returned a terminal result. The
provider operation may still have failed or been cancelled, so match the
terminal status:

```elixir
case Jido.Harness.run(:codex, prompt, cwd: File.cwd!()) do
  {:ok, %Jido.Harness.RunResult{status: :completed} = result} ->
    {:ok, result.text}

  {:ok, %Jido.Harness.RunResult{} = result} ->
    {:error, result.error || result.status}

  {:error, %Jido.Harness.Error{} = error} ->
    {:error, error}
end
```

Read [Choosing a workflow](choosing_a_workflow.md) before adding lifecycle
control to an application.
