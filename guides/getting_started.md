# Getting started

This guide installs Jido.Harness, verifies one provider without sending a
prompt, and makes one live normalized request.

Run Elixir examples in `iex -S mix` from the application that uses Harness.

## Add the dependency

Use Elixir 1.19 or a compatible later version and its supported Erlang/OTP
version. Provider executables must be available to that runtime.

Use the Git dependency to test the version 3 release candidate. Commit your
application's `mix.lock` so that it records the selected revision.

```elixir
def deps do
  [
    {:jido_harness, github: "agentjido/jido_harness", branch: "main"}
  ]
end
```

Fetch dependencies and compile the application:

```console
mix deps.get
mix compile
```

Jido.Harness starts its registries, dynamic supervisors, task supervisors, and
retention worker with the application. The ten built-in adapters require no
registration.

## Install and authenticate a provider CLI

Provider CLIs remain responsible for authentication. Each provider also needs
an ACP entry point. Some CLIs include it. Other providers use a separate ACP
adapter. Preview the required installation:

```elixir
Jido.Harness.install(:codex, dry_run: true)
```

The plan includes the base CLI and its separate ACP adapter. To install both:

```elixir
Jido.Harness.install(:codex)
```

Authenticate with the provider's CLI before making a live request. Harness
does not copy or manage credentials. See [Providers](providers.md) for entry
points and authentication details.

Then ask Jido.Harness for a non-billable status report:

```console
mix jido_harness.check --providers codex
```

The report distinguishes:

- whether the executable is installed;
- whether its version is compatible;
- whether authentication is known, unknown, or unavailable;
- whether the ACP executable is present;
- whether both parts are ready for a request.

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

## Make a request from Elixir

```elixir
alias Jido.Harness.RunResult

{:ok, %RunResult{status: :completed} = result} =
  Jido.Harness.run(:codex, "Reply with exactly: harness-ready",
    cwd: File.cwd!(),
    runtime_timeout_ms: 300_000,
    await_timeout: 320_000
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
        sandbox_mode: :workspace_write
      },
      session_defaults: %{
        sandbox_mode: :workspace_write,
        approval_mode: :prompt
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

  {:error, :timeout} ->
    {:error, :still_running}

  {:error, %Jido.Harness.Error{} = error} ->
    {:error, error}

  {:error, reason} ->
    {:error, reason}
end
```

An await timeout leaves the run active. Use [Runs](runs.md#start-a-detached-run)
when you need its ID before waiting, so later code can cancel or await it.

Read [Choose an API](overview.md#choose-an-api) before adding lifecycle
control to an application.
