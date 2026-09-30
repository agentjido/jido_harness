# Security and sandboxing

Jido.Harness controls process ownership and normalizes provider options, but a
coding-agent CLI still executes with the operating-system permissions of the
BEAM process. Treat every provider run as code execution.

## Prefer structured process execution

Built-in adapters pass an executable and argv directly to the process manager.
They never interpolate a shell command. Applications using
`Jido.Harness.Process` should do the same.

Use `unsafe_shell_spec/2` only when shell parsing is explicitly required and
all interpolated input is trusted.

## Sandbox and approval modes

Normalized request values include:

```elixir
approval_modes = [:default, :prompt, :auto_edit, :auto_approve]
sandbox_modes = [:default, :read_only, :workspace_write, :unrestricted]
```

These are requested semantics, not a universal operating-system sandbox.
ACP profiles declare which values they can represent. A provider may reject a
mode or enforce it differently in its ACP agent. Unsupported values fail before
execution.

## Credentials

Prefer provider-managed cached login or environment variables. Do not place
credentials in:

- prompts;
- argv;
- metadata;
- telemetry metadata;
- provider-visible failure artifacts.

Environment overlays accept string names with string, `false`, or `nil` values.
Use `false` or `nil` to remove inherited variables when constructing a child
environment.

To limit inherited environment values, set `env_mode: :replace` and provide
only the minimal environment required by that provider. Runs and sessions use
the same ACP process path, so replacement mode has the same meaning in both
workflows. Replacement mode limits environment inheritance. It does not
isolate filesystem access or network access, and it does not replace the
provider's sandbox. Provider environment hooks can also add declared values.

## Structured-output isolation

No built-in version 3 ACP profile advertises structured output. Harness rejects
`structured_output` before it starts the agent. See the
[migration guide](migrations/migration_v3.md#structured-output-and-isolation)
for changes from the old direct-Codex contract.

## Redaction

Jido.Harness redacts structured sensitive fields, bearer credentials, and
configured credential environment values before journal persistence.
Environment values and complete process specifications are not journaled.

Redaction is defense in depth, not authorization. Arbitrary secrets embedded in
unstructured provider text may not be identifiable. Keep secrets out of model
input and treat retained output as sensitive.

## Journal permissions

Harness journal directories use mode `0700` and journal files use mode `0600`.
Raw provider records are not persisted. Even with those controls, journals can
contain source fragments, command output, filenames, or model responses and
must follow the application's data-retention policy.

## Provider extensions and project trust

Provider-local settings, MCP servers, extensions, skills, and context files can
execute or influence provider behavior. Enable them deliberately.

## Additional directories

When a profile supports it, `add_dirs` requests access beyond `cwd`. Validate
those paths at the application boundary and do not accept arbitrary user paths
without an authorization decision.

## Telemetry

Built-in telemetry metadata omits prompts, credentials, environment values, and
complete argv. Application handlers should preserve the same boundary when
adding metadata or exporting events.
