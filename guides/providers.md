# Providers and capabilities

Jido.Harness includes nine direct CLI adapters. Each adapter declares the
executable it expects, finite-run capabilities, supported normalized options,
provider-specific options, installation guidance, and interactive transports.

Use the declarations instead of inferring support from a provider name:

```elixir
Jido.Harness.providers()
```

Each entry is a `Jido.Harness.AdapterSpec`.

## Provider inventory

| Provider | Atom | Executable | Resume | Session transport | Process model |
| --- | --- | --- | --- | --- | --- |
| Amp | `:amp` | `amp` | yes | `:stream_json_resume` | process per turn |
| Claude Code | `:claude` | `claude` | yes | `:stream_json_resume` | process per turn |
| Codex | `:codex` | `codex` | yes | `:exec_jsonl_resume` | process per turn |
| Gemini CLI | `:gemini` | `gemini` | yes | `:stream_json_resume` | process per turn |
| Grok | `:grok` | `grok` | yes | `:streaming_json_resume` | process per turn |
| Kimi Code | `:kimi` | `kimi` | yes | `:acp` | persistent process |
| OpenCode | `:opencode` | `opencode` | no finite-run resume | `:acp` | persistent process |
| Pi | `:pi` | `pi` | yes | `:rpc` | persistent process |
| Z.AI | `:zai` | `claude` | yes | `:stream_json_resume` | process per turn |

Z.AI uses its officially supported Claude Code environment mapping while
remaining a distinct `:zai` provider.

## Finite-run output capabilities

All built-in providers stream normalized events and support process-group
cancellation. Capability flags describe whether a provider protocol supplies a
canonical form of optional data.

| Provider | Thinking | Tool events | Usage | Structured file-change events |
| --- | --- | --- | --- | --- |
| Amp | yes | yes | yes | no |
| Claude | yes | yes | yes | no |
| Codex | yes | yes | yes | yes |
| Gemini | no | yes | yes | no |
| Grok | yes | yes | yes | no |
| Kimi | no | yes | no | no |
| OpenCode | no | no | no | no |
| Pi | yes | yes | yes | no |
| Z.AI | yes | yes | yes | no |

"No structured file-change events" does not mean a provider cannot modify
files. It means its current adapter does not claim a reliable canonical
`:file_change` event.

## Interactive capabilities

Managed resume transports provide harness-managed multi-turn context,
follow-up queuing, process interruption, and managed configuration between
turns. They do not claim native steering or approval exchange.

Persistent transports expose more protocol-native behavior:

| Provider | Native multi-turn | Native interrupt | Native approvals | Native steering | Dynamic configuration |
| --- | --- | --- | --- | --- | --- |
| Kimi | yes | yes | yes | no | no |
| OpenCode | yes | yes | yes | no | no |
| Pi | yes | yes | no | yes | native |

Codex's managed transport supports attachment input by translating it per turn.
Kimi and OpenCode expose native multimodal capability through ACP. Other
transport declarations currently do not advertise multimodal input.

## Inspect runtime readiness

```elixir
{:ok, %Jido.Harness.ProviderStatus{} = status} =
  Jido.Harness.status(:codex)

Jido.Harness.ProviderStatus.ready?(status)
```

`ProviderStatus` includes installation, compatibility, authentication,
readiness, version, executable, finite-run capabilities, and session transport
specifications. Authentication may be `:unknown` for cached-login CLIs.

The equivalent operator command is:

```console
mix jido_harness.check --providers codex --strict
```

## Normalized options and provider options

Common request concepts use normalized fields such as `model`,
`provider_session_id`, `system_prompt`, `approval_mode`, `sandbox_mode`,
`attachments`, and `reasoning_effort`. A provider accepts only the subset it
declares.

Provider-specific escape hatches are nested:

```elixir
Jido.Harness.Run.start(:grok, %{
  prompt: "Review this change",
  cwd: File.cwd!(),
  provider_options: %{
    allow_rules: ["Bash(git *)"],
    deny_rules: ["Bash(git push *)"]
  }
})
```

Unknown keys and provider options that shadow normalized fields fail before
execution. Inspect `AdapterSpec.normalized_options`, `normalized_values`, and
`provider_options` for the exact selected-provider contract.

## Provider selection is explicit

Jido.Harness does not rank, route, or fall back between providers. Pass a
provider atom or configure one default. A failed billable run is never retried
through another provider automatically.
