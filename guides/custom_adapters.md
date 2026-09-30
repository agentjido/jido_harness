# Custom adapters

A provider adapter describes its base CLI and one ACP entry point. Harness
owns runs, sessions, processes, and results. ExMCP owns ACP framing, validation,
and protocol request correlation.

## Required callbacks

| Callback | Return value |
| --- | --- |
| `spec/0` | A validated `Jido.Harness.AdapterSpec` |
| `status/1` | `{:ok, ProviderStatus.t()}` or `{:error, reason}` |

A version 3 adapter does not implement `run/2`, `cancel/2`, session transports,
or ACP JSON parsing.

## Minimal native profile

```elixir
defmodule MyApp.HarnessAdapter do
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{ACPAgentSpec, AdapterSpec, Capabilities, ProviderStatus}

  @impl true
  def spec do
    AdapterSpec.new!(
      provider: :my_provider,
      name: "My Provider",
      executable: "my-provider",
      capabilities: Capabilities.new!(resume?: true),
      acp_agent: ACPAgentSpec.native("my-provider", ["acp"],
        capabilities: %{load_session: true}
      ),
      normalized_options: [:provider_session_id, :mcp_config],
      provider_options: []
    )
  end

  @impl true
  def status(config) do
    executable = System.find_executable(Map.get(config, :cli_path, spec().executable))
    installed = not is_nil(executable)

    {:ok,
     ProviderStatus.new!(
       provider: :my_provider,
       installed: installed,
       compatible: installed,
       authenticated: :unknown,
       smoke_ready: installed,
       executable: executable,
       capabilities: spec().capabilities
     )}
  end
end
```

This example checks executable availability and declares no version floor.
Add the provider's version and authentication checks before using a profile
that requires them. `status/1` must not send a model prompt.
`Jido.Harness.status/1` adds ACP executable readiness;
`ProviderStatus.ready?/1` requires both CLI and ACP readiness.

## Register the provider

Put the registration in the host application's configuration:

```elixir
config :jido_harness,
  providers: %{my_provider: MyApp.HarnessAdapter},
  provider_config: %{
    my_provider: %{acp_path: "/opt/my-provider/bin/my-provider"}
  }
```

Registrations merge over built-ins. An existing provider atom overrides its
built-in adapter. See the [configuration reference](reference/configuration_reference.md).

## Declare options and capabilities

`AdapterSpec` defines provider identity, base-CLI installation data, normalized
options, accepted values, provider options, and request defaults.
`ACPAgentSpec` defines the ACP executable, arguments, source, optional package
and authentication method, maturity, and session capabilities.

Declare supported fields in `session_options`, `turn_options`, and
`configuration_options`. Declare provider extensions separately in
`session_provider_options` and `turn_provider_options`. Using `:adapter` for
an option list delegates to the corresponding `AdapterSpec` declaration.

Declarations are checked before a run or session dispatches work. Unknown
options, unsupported values, and unavailable capabilities return errors.
Only advertise behavior the selected ACP entry point implements.

## Separate ACP adapter programs

Use `ACPAgentSpec.adapter/3` when another program translates the base CLI's
protocol into ACP:

```elixir
ACPAgentSpec.adapter("my-provider-acp", "my-provider-acp@1.2.3",
  capabilities: %{load_session: true}
)
```

Declare an exact package version. `Jido.Harness.install/2` installs the base
CLI and the separate ACP package. Installation is an explicit operation and
supports `dry_run: true`. A request or provider configuration can override ACP
executable discovery with `acp_path`.

## Optional callbacks

| Callback | Purpose | Return value |
| --- | --- | --- |
| `install/2` | Install the base CLI | `{:ok, result}` or `{:error, reason}` |
| `acp_env/2` | Map provider configuration and request values to the child environment | `{:ok, map}` or `{:error, reason}` |
| `acp_validate_request/1` | Reject invalid provider option combinations | `:ok` or `{:error, reason}` |
| `acp_validate_capabilities/2` | Check the initialize response before authentication and session creation | `:ok` or `{:error, reason}` |
| `acp_configuration/1` | Map normalized configuration fields to ACP IDs and values | A map |

Environment hooks receive a `SessionRequest` for both finite runs and
interactive sessions. Preserve the request's environment policy. Do not
create lifecycle state or send prompts from these hooks.

Configuration mapping applies at session opening and at runtime. Codex uses
it to translate normalized sandbox values into an ACP mode. See
[Providers](providers.md) for current profile limits.

## Verify the profile

Use a fake ACP executable for initialization, prompts, updates, permission
requests, cancellation, malformed frames, and process cleanup. Add explicit
live checks for the real entry point. Follow [Testing](testing.md) before
release.

The [architecture reference](reference/architecture.md) describes the boundary
an adapter must preserve.
