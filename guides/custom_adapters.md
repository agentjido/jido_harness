# Custom adapters

A custom provider implements `Jido.Harness.Adapter` and returns one
`AdapterSpec` with one `ACPAgentSpec`.

## Minimal adapter

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
      capabilities: Capabilities.new!(),
      acp_agent: ACPAgentSpec.native("my-provider", ["acp"],
        capabilities: %{load_session: true, multimodal: true},
        turn_options: [:attachments, :content]
      ),
      normalized_options: [:model, :provider_session_id, :attachments],
      provider_options: []
    )
  end

  @impl true
  def status(_config) do
    {:ok,
     ProviderStatus.new!(
       provider: :my_provider,
       installed: true,
       compatible: true,
       authenticated: :unknown,
       smoke_ready: true,
       capabilities: spec().capabilities
     )}
  end
end
```

The adapter does not implement `run/2`, session transport callbacks, ACP
framing, event mapping, or protocol correlation. Harness and ExMCP provide
those functions.

## Register the provider

```elixir
config :jido_harness,
  providers: %{my_provider: MyApp.HarnessAdapter},
  provider_config: %{
    my_provider: %{acp_path: "/opt/my-provider/bin/my-provider"}
  }
```

Registrations merge over built-ins. A built-in provider atom is an explicit
override.

## Adapter-backed ACP

Use `ACPAgentSpec.adapter/3` when ACP is a separate program:

```elixir
ACPAgentSpec.adapter("my-provider-acp", "my-provider-acp@1.2.3",
  capabilities: %{load_session: true}
)
```

Use an exact package version. `Jido.Harness.install/2` then includes this
package. A caller can override executable discovery with `acp_path`.

## Environment mapping

Implement optional `acp_env/2` only when the ACP process needs provider-specific
credential or endpoint mapping. Return a map of child environment values. Do
not read prompts or create lifecycle state in this callback.

## Test the contract

Use a fake ACP executable to test initialization, prompts, updates, approvals,
cancellation, process cleanup, and invalid frames. Add opt-in live tests for the
real ACP entry point.
