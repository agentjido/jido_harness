defmodule Jido.Harness.PortACPSessionTest do
  # An ACP session whose agent runs through the port driver, the one Windows
  # uses. On Windows the agent is started through a .cmd file, as the
  # commands npm installs there are.
  use ExUnit.Case, async: false

  alias Jido.Harness.TestHelpers

  setup do
    providers = Application.get_env(:jido_harness, :providers)
    config = Application.get_env(:jido_harness, :provider_config)
    driver = Application.get_env(:jido_harness, :process_driver)
    dir = Path.join(System.tmp_dir!(), "jido-harness-port-acp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    Application.put_env(:jido_harness, :process_driver, Jido.Harness.ProcessDriver.Port)
    Application.put_env(:jido_harness, :providers, %{kimi: Jido.Harness.Adapters.Kimi})

    Application.put_env(:jido_harness, :provider_config, %{
      kimi: %{acp_path: agent(dir), retention: %{journal_dir: Path.join(dir, "journal")}}
    })

    on_exit(fn ->
      TestHelpers.cleanup_sessions()
      TestHelpers.cleanup_processes()
      restore(:providers, providers)
      restore(:provider_config, config)
      restore(:process_driver, driver)
      File.rm_rf(dir)
    end)

    :ok
  end

  test "turns run, a long reply arrives whole, and closing ends the agent" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:kimi, %{})
    assert {:ok, %{provider_session_id: "acp-fixture-session"}} = await_ready(session_id)

    assert {:ok, first} = Jido.Harness.Session.send_message(session_id, "first")
    assert {:ok, %{status: :completed, text: "fixture-ok"}} = Jido.Harness.Session.await(session_id, first, 15_000)

    assert {:ok, large} = Jido.Harness.Session.send_message(session_id, "large")
    assert {:ok, %{status: :completed, text: text}} = Jido.Harness.Session.await(session_id, large, 15_000)
    assert byte_size(text) == 10_000

    process =
      Enum.find(Jido.Harness.Process.list(), fn process ->
        process.metadata[:session_id] == session_id and process.metadata[:protocol] == :acp
      end)

    assert %{state: :running} = process
    assert :ok = Jido.Harness.Session.close(session_id)
    assert {:ok, %{state: state}} = Jido.Harness.Process.await(process.process_id, 20_000)
    assert state in [:exited, :cancelled, :failed]
  end

  defp agent(dir) do
    fixture = TestHelpers.fixture_path("fake_acp_cli.py")

    case :os.type() do
      {:win32, _name} ->
        python = System.find_executable("python") || System.find_executable("python3")
        path = Path.join(dir, "agent.cmd")
        File.write!(path, "@\"#{windows(python)}\" \"#{windows(fixture)}\" %*\r\n")
        path

      _other ->
        fixture
    end
  end

  defp windows(path), do: String.replace(path, "/", "\\")

  defp await_ready(session_id, attempts \\ 300)
  defp await_ready(_session_id, 0), do: flunk("session did not become ready")

  defp await_ready(session_id, attempts) do
    case Jido.Harness.Session.info(session_id) do
      {:ok, %{state: :idle, provider_session_id: id} = info} when is_binary(id) ->
        {:ok, info}

      {:ok, %{state: state} = info} when state in [:failed, :closed] ->
        flunk("session ended while starting: #{inspect(info)}")

      _other ->
        Process.sleep(50)
        await_ready(session_id, attempts - 1)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:jido_harness, key)
  defp restore(key, value), do: Application.put_env(:jido_harness, key, value)
end
