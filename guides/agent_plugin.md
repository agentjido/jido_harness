# Wrap a coding agent in Jido V3

Use one Harness plugin per Jido Agent. The Agent declaration selects one
provider. Each activation opens its own conversation on the first committed
prompt and reuses that conversation for later prompts. Start separate Agent
instances when two conversations need separate context.

## Add Jido to the host app

The plugin ships in `jido_harness`. The host adds Jido V3 directly. For the
Git release candidate, use the same Jido revision as Harness. The standalone
Hex build uses the `package` Mix environment until a compatible Jido V3
release is available on Hex.

```elixir
{:jido, github: "agentjido/jido", ref: "ec96da6015b4b1e5a1642d50651235d9d52808ec"}
```

Harness can also run as a standalone dependency. Its optional Jido
dependency does not start a Jido instance. The host starts the instance and
the Agents that use the plugin. If you add Jido after Mix has already compiled
Harness, rebuild the dependency once so Mix compiles the plugin modules.

```console
mix deps.get
mix deps.compile
mix deps.compile jido_harness --force
```

## Declare one provider

```elixir
defmodule MyApp.CodexAgent do
  use Jido.Agent, name: "codex_agent", plugins: [Jido.Harness.Plugin]

  harness do
    provider :codex
    cwd env("REPO_AGENT_WORKSPACE")
    sandbox_mode :workspace_write
  end

  routes do
    route "jido.harness.command.*", Jido.Harness.Plugin.Execute
  end
end
```

Add routes for the result Signals your app uses. The
executable examples in `guides/recipes/agent_wrappers.exs` include routes
for Codex, Claude Code, and Amp. Claude Code and Amp use their provider
defaults for sandbox mode. A wrapper can set `model` to an available provider
model. See the [provider profiles](providers.md) for provider options.

Set the working directory in trusted host configuration. Commands supply the
text or control data only. Authenticate and authorize external callers before
converting their input to a command Signal.

## Send prompts and handle results

Call the Agent with a typed command Signal. The return value confirms the Jido
turn. The plugin submits the prompt after commit.

```elixir
alias Jido.Harness.Plugin.Command

{:ok, _turn} = Jido.AgentServer.call(agent, Command.prompt("request-1", "Summarize this repository."))
```

| Signal | Use |
| --- | --- |
| `jido.harness.turn.accepted` | Correlate the host request ID with the Harness turn ID. |
| `jido.harness.turn.delta` | Read ordered text progress with its sequence number. |
| `jido.harness.turn.finished` | Read the terminal status and retained text, or the failure code. |
| `jido.harness.error.command` | Handle command rejection, including a full queue or a stale control request. |
| `jido.harness.approval.requested` | Apply host policy to a pending permission request. |

Use `Command.interrupt(request_id, turn_id)` to cancel the active turn by ID.
Use `Command.respond_approval(request_id, approval_id, :approve | :deny)` to
answer a permission request once. If no response arrives, Harness denies the
request when its approval timer expires. Responses apply to one request. The
approval Signal contains a local approval ID and a short summary. The host can
deny requests it cannot evaluate.

Harness bounds queued turns and retained results. The plugin remembers recent
prompt IDs for the current activation. Results go to that live Agent on a
best-effort basis. If the Agent or its plugin runtime stops, Harness closes
its provider session. A new activation starts a new conversation. Provider
context can also expire when the configured session idle timeout elapses.

The [testing guide](testing.md) gives the opt-in command for the live wrappers.
