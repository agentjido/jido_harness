defmodule Jido.Harness.ACPSessionTest do
  use ExUnit.Case, async: false

  setup do
    providers = Application.get_env(:jido_harness, :providers)
    config = Application.get_env(:jido_harness, :provider_config)
    fixture = Jido.Harness.TestHelpers.fixture_path("fake_acp_cli.py")
    journal_dir = Path.join(System.tmp_dir!(), "jido-harness-acp-#{System.unique_integer([:positive])}")

    Application.put_env(:jido_harness, :providers, %{kimi: Jido.Harness.Adapters.Kimi})

    Application.put_env(:jido_harness, :provider_config, %{
      kimi: %{cli_path: fixture, retention: %{journal_dir: journal_dir}}
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

  test "ACP correlates fragmented JSONL responses and preserves context identity" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:kimi, %{})
    assert {:ok, %{provider_session_id: "acp-fixture-session", transport: :acp}} = await_ready(session_id)

    assert {:ok, first_id} = Jido.Harness.Session.send_message(session_id, "first")
    assert {:ok, %{status: :completed, text: "fixture-ok"}} = Jido.Harness.Session.await(session_id, first_id, 2_000)

    assert {:ok, second_id} = Jido.Harness.Session.send_message(session_id, "invalid frame")
    assert {:ok, %{status: :completed, text: "fixture-ok"}} = Jido.Harness.Session.await(session_id, second_id, 2_000)

    assert {:ok, events} = Jido.Harness.Session.replay(session_id, limit: 1_000)
    assert Enum.any?(events, &(&1.payload["kind"] == "decode_error"))
    assert :ok = Jido.Harness.Session.close(session_id)
  end

  test "ACP translates permission requests and rejects stale responses" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:kimi, %{})
    assert {:ok, _info} = await_ready(session_id)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "request approval")
    assert {:ok, %{pending_approvals: 1}} = await_approval(session_id)

    assert {:ok, events} = Jido.Harness.Session.replay(session_id, limit: 1_000)
    request_id = Enum.find(events, &(&1.type == :approval_requested)).request_id
    assert :ok = Jido.Harness.Session.respond_approval(session_id, request_id, :approve)
    assert {:error, :not_found} = Jido.Harness.Session.respond_approval(session_id, request_id, :deny)
    assert {:ok, %{status: :completed, text: "approved"}} = Jido.Harness.Session.await(session_id, turn_id, 2_000)
  end

  test "approval timeouts deny the provider request without closing the session" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:kimi, %{approval_timeout_ms: 25})
    assert {:ok, _info} = await_ready(session_id)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "request approval")
    assert {:ok, %{status: :completed, text: "denied"}} = Jido.Harness.Session.await(session_id, turn_id, 2_000)
    assert {:ok, %{state: :idle, pending_approvals: 0}} = Jido.Harness.Session.info(session_id)

    assert {:ok, events} = Jido.Harness.Session.replay(session_id, limit: 1_000)
    assert Enum.any?(events, &(&1.type == :approval_resolved and &1.payload["reason"] == "timeout"))
  end

  test "duplicate approval notifications replace their timer without racing the response" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:kimi, %{approval_timeout_ms: 500})
    assert {:ok, _info} = await_ready(session_id)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "duplicate approval")
    assert {:ok, %{pending_approvals: 1}} = await_approval(session_id)

    assert {:ok, events} = Jido.Harness.Session.replay(session_id, limit: 1_000)
    approvals = Enum.filter(events, &(&1.type == :approval_requested))
    assert length(approvals) == 2
    assert Enum.uniq_by(approvals, & &1.request_id) |> length() == 1

    assert :ok = Jido.Harness.Session.respond_approval(session_id, hd(approvals).request_id, :approve)
    assert {:ok, %{status: :completed, text: "approved"}} = Jido.Harness.Session.await(session_id, turn_id, 2_000)
    Process.sleep(550)
    assert {:ok, %{state: :idle, pending_approvals: 0}} = Jido.Harness.Session.info(session_id)
  end

  test "ACP rejects ignored session and turn options before dispatch" do
    assert {:error, %Jido.Harness.Error{details: %{field: :model}}} =
             Jido.Harness.Session.start(:kimi, %{model: "ignored"})

    assert {:error, %Jido.Harness.Error{message: "unknown provider option"}} =
             Jido.Harness.Session.start(:kimi, %{provider_options: %{extra_args: ["--unsafe"]}})

    assert {:ok, session_id} = Jido.Harness.Session.start(:kimi)
    assert {:ok, _info} = await_ready(session_id)

    assert {:error, %Jido.Harness.Error{details: %{field: :reasoning_effort}}} =
             Jido.Harness.Session.send_message(session_id, %{prompt: "hello", reasoning_effort: :high})
  end

  defp await_ready(session_id, attempts \\ 100)
  defp await_ready(_session_id, 0), do: {:error, :timeout}

  defp await_ready(session_id, attempts) do
    case Jido.Harness.Session.info(session_id) do
      {:ok, %{state: :idle, provider_session_id: id}} = result when is_binary(id) ->
        result

      _ ->
        Process.sleep(20)
        await_ready(session_id, attempts - 1)
    end
  end

  defp await_approval(session_id, attempts \\ 100)
  defp await_approval(_session_id, 0), do: {:error, :timeout}

  defp await_approval(session_id, attempts) do
    case Jido.Harness.Session.info(session_id) do
      {:ok, %{pending_approvals: 1}} = result ->
        result

      _ ->
        Process.sleep(20)
        await_approval(session_id, attempts - 1)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:jido_harness, key)
  defp restore(key, value), do: Application.put_env(:jido_harness, key, value)
end
