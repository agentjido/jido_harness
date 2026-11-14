# Use Harness with consolidated Jido v3

Harness is a standalone provider runtime. Consolidated Jido owns the Agent,
Action, Signal, and AI modules. Harness owns `Event`, `ProcessEvent`, run and
session lifecycle, replay, and provider normalization. It has no required core
runtime dependency. The host owns the link between those contracts.

## Host integration

Put a Harness Event in a host Signal. Keep its run or session identity and
sequence so the host can track ordering. Route that Signal to an Action in the
host Agent. The host must define policy for cancellation, permissions, and
resource cleanup. Do not treat provider output as a command to execute.

```elixir
event = Jido.Harness.Event.new!(%{
  type: :output_text_final,
  provider: :codex,
  run_id: "example-run",
  sequence: 1,
  payload: %{"text" => "offline result"}
})

signal = Jido.Signal.new!("host.harness.output", %{event: event}, source: "/host/harness")
```

The [consumer fixture](../integration/jido_v3/README.md) checks an actual core
Action and AgentServer call. It needs no provider credentials and makes no
model call. Run `mix deps.get` and `mix test` in `integration/jido_v3`.

## Branch reconciliation

The candidate starts from `main` at `20fe00f7e954b8634b5ca73fc8cb7ee55230de24`.
The `release/v3` branch at `771bacec2c49a30b393c3d6f53b258700b5a6071`
contains three later commits. Its first commit replaces the Event contract
with Signals from a separate `jido_signal` package. Its second commit removes
the Agent integration spike. Its third commit adds Amp Orb control.

This candidate keeps the main Event API and the separate Amp Orb feature.
The Amp CLI reader now consumes `ProcessEvent` records. It keeps process
lifetime, output limits, cancellation, replay, and error handling from main.
See [Amp Orbs](amp_orbs.md). The existing `:amp` ACP provider remains available.
The former Agent spike stays removed.

This is compatible with current Event consumers. It does not implement the
old branch's Signal API, signal journal format, or Signal subscription
messages. Applications that used that branch must keep it pinned until they
migrate to `Event` and `ProcessEvent`. Do not replay a Signal journal as an
Event journal without an explicit data migration. No stored data is changed.
The old branch remains available; it is not reset or force-pushed.

Use only consolidated Jido in a v3 host graph. Do not add separate legacy
Action, Signal, or AI packages. Package v3 and core v3 version numbers do not
by themselves prove host compatibility.
