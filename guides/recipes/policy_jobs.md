# Bounded jobs with approval policy

Use a session when one finite task needs an application decision for each
permission request. `Jido.Harness.run/3` does not accept approval callbacks and
rejects `approval_mode: :prompt`.

The tested [policy job recipe](policy_job.exs) opens one session, sends one
turn, answers approval requests, and closes the session on exit. It is example
application code, not a public Harness module.

## Load and run

From a source checkout, start `iex -S mix` and load the recipe:

```elixir
Code.require_file("guides/recipes/policy_job.exs")

policy = fn _request -> :deny end

Jido.Harness.Examples.PolicyJob.run(
  :codex,
  "Review this workspace",
  policy,
  timeout_ms: 30_000,
  policy_timeout_ms: 1_000,
  session_options: %{cwd: File.cwd!(), approval_mode: :prompt}
)
```

Replace the policy with your application's permission rules. It must return
`:approve` or `:deny`. Exceptions, invalid replies, and policy timeouts deny
the request. The turn budget starts after session startup.

Configure the provider to send permission requests for operations that need
review. The recipe can answer only requests that the provider sends. Options
must be supported by that provider. For example, OpenCode supports ACP
permission requests but does not accept the normalized `approval_mode` option.

## Verification

`test/jido_harness/policy_job_example_test.exs` loads this same source file. It
checks approval, denial, policy failure, deadline expiry, and process cleanup
with fake providers. It also checks OpenCode permissions without an
approval-mode option.

See [Interactive sessions](../interactive_sessions.md) for the public API and
[Ownership, timeouts, and cancellation](../ownership_timeouts_and_cancellation.md)
for resource lifetime.
