defmodule Jido.Harness.PiACPSessionTest do
  use ExUnit.Case, async: false

  setup do
    providers = Application.get_env(:jido_harness, :providers)
    config = Application.get_env(:jido_harness, :provider_config)
    fixture = Jido.Harness.TestHelpers.fixture_path("fake_acp_cli.py")
    journal_dir = Path.join(System.tmp_dir!(), "jido-harness-pi-#{System.unique_integer([:positive])}")

    Application.put_env(:jido_harness, :providers, %{pi: Jido.Harness.Adapters.Pi})

    Application.put_env(:jido_harness, :provider_config, %{
      pi: %{acp_path: fixture, retention: %{journal_dir: journal_dir}}
    })

    on_exit(fn ->
      Jido.Harness.TestHelpers.cleanup_sessions()
      Jido.Harness.TestHelpers.cleanup_processes()
      restore(:providers, providers)
      restore(:provider_config, config)
      File.rm_rf!(journal_dir)
    end)

    :ok
  end

  test "Pi uses the common ACP session and configuration path" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:pi)
    assert {:ok, %{provider_session_id: "acp-fixture-session"}} = await_ready(session_id)

    assert :ok = Jido.Harness.Session.configure(session_id, %{reasoning_effort: :high})
    assert {:ok, first_id} = Jido.Harness.Session.send_message(session_id, "first")

    assert {:ok, %{status: :completed, text: "fixture-ok"}} =
             Jido.Harness.Session.await(session_id, first_id, 2_000)

    assert {:ok, held_id} = Jido.Harness.Session.send_message(session_id, "wait")

    assert {:error, %Jido.Harness.Error{details: %{capability: :steer}}} =
             Jido.Harness.Session.steer(session_id, "finish")

    assert :ok = Jido.Harness.Session.interrupt(session_id, held_id)
    assert {:ok, %{status: :interrupted}} = Jido.Harness.Session.await(session_id, held_id, 2_000)
  end

  test "Pi declares unsupported ACP features before process dispatch" do
    assert {:error, %Jido.Harness.Error{message: "ACP agent does not support MCP servers"}} =
             Jido.Harness.Session.start(:pi, %{mcp_config: %{test: %{command: "test"}}})
  end

  defp await_ready(session_id, attempts \\ 100)
  defp await_ready(_session_id, 0), do: {:error, :timeout}

  defp await_ready(session_id, attempts) do
    case Jido.Harness.Session.info(session_id) do
      {:ok, %{state: :idle, provider_session_id: id}} = result when is_binary(id) ->
        result

      _ ->
        Process.sleep(10)
        await_ready(session_id, attempts - 1)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:jido_harness, key)
  defp restore(key, value), do: Application.put_env(:jido_harness, key, value)
end
