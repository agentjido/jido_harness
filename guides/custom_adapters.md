# Custom adapters

Applications can register a custom provider or override a built-in provider by
implementing `Jido.Harness.Adapter` and returning an explicit
`Jido.Harness.AdapterSpec`.

## Adapter responsibilities

A finite-run adapter must:

- declare its provider identity, executable, capabilities, normalized options,
  provider options, defaults, and session transports;
- receive a validated `Jido.Harness.RunRequest`;
- return an enumerable of normalized `Jido.Harness.Event` values;
- report a normalized `Jido.Harness.ProviderStatus`;
- use the supplied process manager for CLI processes;
- preserve terminal and cancellation semantics.

It must not return arbitrary provider maps, start unmanaged processes, retry a
billable run, or silently ignore an advertised option.

## Minimal behaviour shape

```elixir
defmodule MyApp.HarnessAdapter do
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Capabilities, ProviderStatus}

  @impl true
  def spec do
    AdapterSpec.new!(
      provider: :my_provider,
      name: "My Provider",
      executable: "my-provider",
      capabilities: Capabilities.new!(streaming?: true),
      normalized_options: [:model],
      provider_options: []
    )
  end

  @impl true
  def status(config) do
    # Inspect executable and compatibility without sending a prompt.
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

  @impl true
  def run(request, context) do
    # Start through context.process_manager and return canonical events.
    {:ok, normalized_event_stream(request, context)}
  end
end
```

In real code, construct specs and statuses with `new!/1` or return already
validated structs. The example is intentionally schematic; see the
[adapter contract reference](../docs/adapter_contract.md) for callback and
terminal requirements.

## Register the provider

```elixir
config :jido_harness,
  providers: %{
    my_provider: MyApp.HarnessAdapter
  },
  provider_config: %{
    my_provider: %{
      request_defaults: %{model: "default-model"}
    }
  }
```

Registrations merge over built-ins. Reusing a built-in atom explicitly
overrides that adapter.

## Normalize conservatively

Map a provider record to a canonical event only when the meaning is preserved.
For example, assistant output can become `:output_text_delta` or
`:output_text_final`, and a verifiable invocation can become `:tool_call`.

When no canonical type is lossless, emit:

```elixir
Jido.Harness.Event.new!(
  type: :provider_event,
  provider: :my_provider,
  payload: %{"kind" => "provider-record"},
  raw: provider_record
)
```

The run manager attaches stable run identity and sequence values. Raw data is
available in memory but is not persisted to journals.

## Declare options precisely

`normalized_options` names shared request fields the provider can represent.
`normalized_values` restricts enum values when support is narrower than the
global schema. `provider_options` declares the accepted nested escape hatches.

Declarations are executable validation, not descriptive hints. Unknown or
unsupported fields fail before `run/2`.

## Interactive transports

Interactive support is declared through one or more
`Jido.Harness.SessionTransportSpec` values. Each spec points to a
`Jido.Harness.SessionAdapter` and separately declares session fields, turn
fields, provider options, configuration fields, and interaction capabilities.

Use `:native`, `:managed`, `:process`, or `false` capability values accurately.
Do not present harness emulation as native protocol behavior.

## Test the contract

Custom adapters should have deterministic fake-CLI tests for mapping, cleanup,
timeouts, cancellation, and terminal uniqueness, plus an explicit opt-in live
contract suite. See [Testing](testing.md).
