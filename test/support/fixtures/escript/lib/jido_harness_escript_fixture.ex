defmodule JidoHarnessEscriptFixture do
  def main(_arguments) do
    cache_dir = System.fetch_env!("JIDO_HARNESS_ESCRIPT_CACHE_DIR")
    Application.put_env(:jido_harness, :process_manager, %{journal_dir: Path.join(cache_dir, "journals")})

    with {:ok, helper_path} <- Jido.Harness.Escript.bootstrap_native(cache_dir: cache_dir),
         {:ok, _applications} <- Application.ensure_all_started(:jido_harness) do
      verify!()
      {:ok, env} = Jido.Harness.Adapters.Antigravity.acp_env(Jido.Harness.SessionRequest.new!(%{}), %{})
      true = String.contains?(env["NODE_OPTIONS"], "--import=data:text/javascript;base64,")
      IO.puts("BOOTSTRAP_OK=" <> helper_path)
    else
      {:error, error} ->
        IO.puts(:stderr, Exception.message(error))
        System.halt(1)
    end
  end

  def verify! do
    {:ok, applications} = :application.get_key(:jido_harness, :applications)
    false = :erlexec in applications
    {:ok, modules} = :application.get_key(:jido_harness, :modules)
    true = :jido_harness_exec in modules
    false = :exec in modules
    manager = Process.whereis(:jido_harness_exec)
    true = is_pid(manager)

    if System.get_env("JIDO_HARNESS_PACKAGE_WITH_ERLEXEC") == "1" do
      external = Process.whereis(:exec)
      true = is_pid(external) and external != manager

      {:ok, [stdout: ["external-native-ok\n"]]} =
        apply(:exec, :run, [["/bin/echo", "external-native-ok"], [:sync, :stdout]])
    else
      nil = Process.whereis(:exec)
    end

    {:ok, process_id} =
      Jido.Harness.Process.start(%{executable: "/bin/echo", argv: ["escript-native-ok"], stdin: false})

    {:ok, %{state: :exited, exit_status: 0}} = Jido.Harness.Process.await(process_id, 5_000)
    {:ok, events} = Jido.Harness.Process.replay(process_id)
    output = events |> Enum.filter(&(&1.type == :stdout)) |> Enum.map(& &1.data) |> IO.iodata_to_binary()
    "escript-native-ok\n" = output
    IO.puts("PACKAGE_CONSUMER_OK")
  end
end
