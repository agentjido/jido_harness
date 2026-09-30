# Escript packaging

Harness includes a native `exec-port` helper to manage OS processes. An
escript can include this file, but it cannot execute a file inside its archive.
Extract and configure the helper before applications start.

## Configure the escript

First add Harness as described in [Getting started](getting_started.md).
In your Mix project, set `app: nil` so Mix does not start Harness before the
main function. Include the native helper and Harness provider assets:

```elixir
def project do
  [
    app: :my_cli,
    version: "0.1.0",
    deps: deps(),
    escript: [
      main_module: MyCLI,
      app: nil,
      include_priv_for: [:jido_harness]
    ]
  ]
end
```

## Bootstrap before application startup

This example checks Codex readiness without sending a prompt:

```elixir
defmodule MyCLI do
  def main(_args) do
    with {:ok, _helper} <- Jido.Harness.Escript.bootstrap_native(),
         {:ok, _applications} <- Application.ensure_all_started(:jido_harness),
         {:ok, status} <- Jido.Harness.status(:codex) do
      IO.inspect(status, label: "Codex readiness")
      unless Jido.Harness.ProviderStatus.ready?(status), do: System.halt(1)
    else
      {:error, reason} ->
        IO.puts(:stderr, "startup failed: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
```

The bootstrap selects `jido_harness/priv/native/SYSTEM_ARCH/exec-port` from the archive.
It writes the helper under the private user-cache directory with mode `0700`
and sets `:jido_harness, :native_process`. Calls with the same content reuse the cached
file.

Set `cache_dir: path` when the default cache is unsuitable:

```elixir
Jido.Harness.Escript.bootstrap_native(cache_dir: cache_dir)
```

Do not bootstrap after Harness starts. Its running port cannot change the
executable path.

## Build and verify

```console
mix escript.build
./my_cli
```

The provider CLI and ACP executable must still be installed and authenticated
on the target host. The archive does not include them.

The Antigravity crash guard is read from the archive and passed to Node as a
module source. It does not require an extra file extraction step.

The target architecture must match the included native helper. Build a
separate artifact for each supported architecture.

The fixture under `test/support/fixtures/escript/` builds and executes a real
escript to check native extraction and managed processes. See
[Testing](testing.md#unit-and-fixture-checks) for verification.

`bootstrap_erlexec/1` remains as a compatibility name for `bootstrap_native/1`.
The external erlexec application is not required.
