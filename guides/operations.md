# Operations

Operating Jido.Harness means ensuring the selected CLIs are present in the BEAM
runtime environment, setting finite execution policies, observing resource
lifecycle, and pruning retained output.

## Runtime environment

Provider executables are resolved from the OS environment seen by the BEAM.
GUI applications, releases, containers, and service managers often receive a
different `PATH` from an interactive shell. A CLI that works in a terminal may
therefore be unavailable to the release.

Check from the same runtime context that will run the application:

```elixir
Jido.Harness.status(:codex)
```

or:

```console
mix jido_harness.check --providers codex --strict
```

Provider configuration can set `provider_config[provider].cli_path` when an
explicit executable path is required. Individual requests may also use the
declared `provider_options.cli_path` escape hatch.

## Application configuration

The principal application keys are:

- `:default_provider`
- `:providers`
- `:provider_config`
- `:process_manager`

Use `:providers` to add or override explicit adapter registrations. Use
`:provider_config` for provider request/session defaults and adapter-specific
runtime configuration. Use `:process_manager` for journal location, retention
TTL, sweep interval, and process-manager defaults.

See the [configuration reference](../docs/configuration_reference.md).

## Readiness versus a live smoke request

`Jido.Harness.status/1` and `mix jido_harness.check` inspect installation,
version compatibility, authentication evidence, and adapter readiness without
sending a prompt.

Some cached-login CLIs cannot prove authentication through inspection. Use one
explicit `mix jido_harness.chat PROVIDER` call when a live end-to-end check is
required. That command may consume provider usage.

Jido.Harness never probes all providers with billable requests automatically.

## Set execution limits deliberately

Runtime and idle timeouts default to `:infinity`. Production call sites should
set limits appropriate to their work and leave extra time for the independent
caller await:

```elixir
Jido.Harness.Run.start(:codex, %{
  prompt: prompt,
  cwd: cwd,
  runtime_timeout_ms: 900_000,
  idle_timeout_ms: 180_000
})
```

Await timeout and execution timeout are intentionally separate.

## Monitor resources

Use lifecycle lists for operational inspection:

```elixir
Jido.Harness.Run.list(states: [:starting, :running])
Jido.Harness.Session.list(states: [:running, :awaiting_approval])
Jido.Harness.Process.list(states: [:starting, :running, :stopping])
```

Each info struct exposes the current output cursor and redacted terminal state.
Avoid polling at very high frequency; event streams are the appropriate path
for output consumption.

## Telemetry

Attach handlers to run, session, adapter, process, and journal events. Telemetry
metadata contains identity and lifecycle context but excludes prompts,
credentials, environment values, and complete argv.

See the [telemetry reference](../docs/telemetry.md).

## Retention and disk capacity

The journal is bounded, segmented, and local to the host. Monitor journal-error
and overflow telemetry, size disk limits for expected output, and treat replay
as retained operational history rather than durable distributed storage.

Terminal resources remain available for 24 hours by default. Explicitly prune
completed resources sooner when an application no longer needs replay.

## Shutdown and restart

On application shutdown, managed process groups are terminated. Stable harness
IDs are meaningful only inside the current application instance; Jido.Harness
does not recover live resources or reconstruct supervisors after restart.

Applications that require durable job state should persist their own external
job record and treat a restarted harness execution as a new resource.
