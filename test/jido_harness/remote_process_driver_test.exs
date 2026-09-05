defmodule Jido.Harness.RemoteProcessDriverTest do
  use ExUnit.Case, async: false

  import Jido.Harness.TestHelpers
  alias Jido.Harness.{Error, ProcessSpec}
  alias Jido.Harness.ProcessDriver.Erlexec

  defmodule RemoteDriver do
    @behaviour Jido.Harness.ProcessDriver

    @impl true
    def start(spec, owner) do
      send(Application.fetch_env!(:jido_harness, :remote_driver_test_pid), {:remote_spec, spec})

      # Simulate a remote host by mapping its working directory to a local
      # fixture directory only at the driver boundary.
      Erlexec.start(%{spec | cwd: System.tmp_dir!()}, owner)
    end

    @impl true
    defdelegate send_input(process, data), to: Erlexec
    @impl true
    defdelegate signal(process, signal), to: Erlexec
  end

  setup do
    driver = Application.get_env(:jido_harness, :process_driver)
    test_pid = Application.get_env(:jido_harness, :remote_driver_test_pid)
    providers = Application.get_env(:jido_harness, :providers)
    config = Application.get_env(:jido_harness, :provider_config)
    Application.put_env(:jido_harness, :remote_driver_test_pid, self())

    on_exit(fn ->
      cleanup_sessions()
      cleanup_runs()
      cleanup_processes()
      restore(:process_driver, driver)
      restore(:remote_driver_test_pid, test_pid)
      restore(:providers, providers)
      restore(:provider_config, config)
    end)

    cwd = Path.join(System.tmp_dir!(), "remote-harness-#{System.unique_integer([:positive])}")
    refute File.exists?(cwd)
    %{cwd: cwd}
  end

  test "a custom driver receives a directory that does not exist on the caller's host", %{cwd: cwd} do
    Application.put_env(:jido_harness, :process_driver, RemoteDriver)
    assert {:ok, spec} = ProcessSpec.new(executable: "/bin/pwd", cwd: cwd, stdin: false)
    assert {:ok, id} = Jido.Harness.Process.start(spec)
    assert_receive {:remote_spec, %ProcessSpec{cwd: ^cwd}}, 1_000
    assert {:ok, %{state: :exited, exit_status: 0}} = Jido.Harness.Process.await(id, 5_000)
    assert {:ok, events} = Jido.Harness.Process.replay(id)
    assert Enum.any?(events, &(&1.type == :stdout))
    assert :ok = Jido.Harness.Process.prune(id)
  end

  test "finite runs pass remote workspace paths to the driver", %{cwd: cwd} do
    Application.put_env(:jido_harness, :process_driver, RemoteDriver)
    Application.put_env(:jido_harness, :providers, %{opencode: Jido.Harness.Adapters.OpenCode})
    argv_path = Path.join(System.tmp_dir!(), "harness-argv-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(argv_path) end)

    assert {:ok, %{status: :completed, provider_session_id: "ses_fixture"}} =
             Jido.Harness.run(:opencode, "remote",
               cwd: cwd,
               env: %{"HARNESS_FIXTURE_ARGV" => argv_path},
               provider_options: %{cli_path: fixture_path("fake_opencode_run.py")},
               await_timeout: 5_000
             )

    assert_receive {:remote_spec, %ProcessSpec{cwd: ^cwd}}
  end

  test "ACP sessions pass remote workspace paths to the driver", %{cwd: cwd} do
    Application.put_env(:jido_harness, :process_driver, RemoteDriver)
    Application.put_env(:jido_harness, :providers, %{kimi: Jido.Harness.Adapters.Kimi})
    Application.put_env(:jido_harness, :provider_config, %{kimi: %{cli_path: fixture_path("fake_acp_cli.py")}})

    assert {:ok, id} = Jido.Harness.Session.start(:kimi, %{cwd: cwd})
    assert_receive {:remote_spec, %ProcessSpec{cwd: ^cwd}}, 1_000
    assert :ok = await_ready(id, 100)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(id, "remote")
    assert {:ok, %{status: :completed, text: "fixture-ok"}} = Jido.Harness.Session.await(id, turn_id, 5_000)
    assert :ok = Jido.Harness.Session.close(id)
  end

  defp await_ready(_id, 0), do: {:error, :timeout}

  defp await_ready(id, attempts) do
    case Jido.Harness.Session.info(id) do
      {:ok, %{state: :idle}} ->
        :ok

      _ ->
        Process.sleep(20)
        await_ready(id, attempts - 1)
    end
  end

  test "Erlexec rejects a missing local directory before starting an OS process", %{cwd: cwd} do
    Application.put_env(:jido_harness, :process_driver, Erlexec)
    assert {:ok, spec} = ProcessSpec.new(executable: "/bin/pwd", cwd: cwd)
    assert {:error, %Error{category: :validation, details: %{cwd: ^cwd}}} = Erlexec.start(spec, self())
    assert {:ok, id} = Jido.Harness.Process.start(spec)
    assert {:ok, info} = Jido.Harness.Process.await(id, 5_000)
    assert info.state == :failed
    assert info.os_pid == nil
    assert %Error{category: :validation} = info.error
    assert {:ok, events} = Jido.Harness.Process.replay(id)
    refute Enum.any?(events, &(&1.type == :started))
    assert :ok = Jido.Harness.Process.prune(id)
    refute Enum.any?(Jido.Harness.Process.list(), &(&1.process_id == id))
  end

  defp restore(key, nil), do: Application.delete_env(:jido_harness, key)
  defp restore(key, value), do: Application.put_env(:jido_harness, key, value)
end
