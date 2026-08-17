# Escript packaging

Jido.Harness uses `erlexec` and its native `exec-port` helper to manage OS
processes. A Mix escript can include this helper, but it cannot execute a file
inside the escript archive. Extract and configure the helper before the
applications start.

## Configure the escript

Set `app: nil` so that Mix does not start `erlexec` before your main function.
Use `include_priv_for: [:erlexec]` to add the native helper to the archive:

```elixir
def project do
  [
    app: :my_cli,
    version: "0.1.0",
    escript: [
      main_module: MyCLI,
      app: nil,
      include_priv_for: [:erlexec]
    ]
  ]
end
```

## Bootstrap before application startup

Call `Jido.Harness.Escript.bootstrap_erlexec/1` before you start
`:jido_harness`:

```elixir
defmodule MyCLI do
  def main(args) do
    with {:ok, _helper_path} <- Jido.Harness.Escript.bootstrap_erlexec(),
         {:ok, _applications} <- Application.ensure_all_started(:jido_harness) do
      run(args)
    else
      {:error, error} ->
        IO.puts(:stderr, Exception.message(error))
        System.halt(1)
    end
  end
end
```

The bootstrap function selects only `erlexec/priv/SYSTEM_ARCH/exec-port` from
the archive. It writes the helper below the private user-cache directory with
mode `0700` and sets the `:erlexec, :portexe` application value. Repeated calls
for the same helper content reuse the cached file.

Use `cache_dir: path` when the default user-cache directory is not suitable:

```elixir
Jido.Harness.Escript.bootstrap_erlexec(cache_dir: cache_dir)
```

Do not call the bootstrap function after `:erlexec` starts. The running port
process cannot change its executable path.

## Build and verify

Build the escript and run a provider readiness check from the packaged CLI:

```console
mix escript.build
./my_cli check codex
```

The target machine must use the same system architecture as the included
`exec-port` file. Build one escript artifact for each supported architecture.
