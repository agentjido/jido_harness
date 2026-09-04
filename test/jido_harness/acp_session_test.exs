defmodule Jido.Harness.ACPSessionTest do
  use ExUnit.Case, async: false

  setup do
    providers = Application.get_env(:jido_harness, :providers)
    config = Application.get_env(:jido_harness, :provider_config)
    fixture = Jido.Harness.TestHelpers.fixture_path("fake_acp_cli.py")
    journal_dir = Path.join(System.tmp_dir!(), "jido-harness-acp-#{System.unique_integer([:positive])}")

    Application.put_env(:jido_harness, :providers, %{kimi: Jido.Harness.Adapters.Kimi})

    Application.put_env(:jido_harness, :provider_config, %{
      kimi: %{acp_path: fixture, retention: %{journal_dir: journal_dir}}
    })

    on_exit(fn ->
      Jido.Harness.TestHelpers.cleanup_sessions()
      Jido.Harness.TestHelpers.cleanup_processes()
      restore(:providers, providers)
      restore(:provider_config, config)
      File.rm_rf!(journal_dir)
    end)

    {:ok, journal_dir: journal_dir}
  end

  test "ExMCP correlates fragmented responses while Harness owns process and event identity", %{
    journal_dir: journal_dir
  } do
    assert {:ok, session_id} = Jido.Harness.Session.start(:kimi, %{})
    assert {:ok, %{provider_session_id: "acp-fixture-session"}} = await_ready(session_id)

    process =
      Enum.find(Jido.Harness.Process.list(), fn process ->
        process.metadata[:session_id] == session_id and process.metadata[:protocol] == :acp
      end)

    assert %{state: :running, metadata: %{provider: :kimi}} = process

    assert {:ok, first_id} = Jido.Harness.Session.send_message(session_id, "first")

    assert {:ok, %{status: :completed, text: "fixture-ok"} = first_result} =
             Jido.Harness.Session.await(session_id, first_id, 2_000)

    assert {:ok, second_id} = Jido.Harness.Session.send_message(session_id, "invalid frame")

    assert {:ok, %{status: :completed, text: "fixture-ok"} = second_result} =
             Jido.Harness.Session.await(session_id, second_id, 2_000)

    assert {:ok, events} = Jido.Harness.Session.replay(session_id, limit: 1_000)
    assert Enum.map(events, & &1.sequence) == Enum.to_list(1..length(events))
    refute Enum.any?(events, &(&1.payload["kind"] == "decode_error"))
    assert Enum.all?(events, &is_nil(&1.raw))
    output = Enum.filter(first_result.events ++ second_result.events, &(&1.type == :output_text_delta))
    assert Enum.map(output, & &1.turn_id) == [first_id, second_id]
    assert length(Enum.uniq(Enum.map(output, & &1.raw["fixturePromptId"]))) == 2
    assert Enum.all?(output, &(&1.raw["method"] == "session/update"))
    assert Enum.all?(output, &(&1.raw["providerEnvelope"]["secret"] == "raw-only-secret"))

    journal_files = Path.wildcard(Path.join([journal_dir, "**", "*.jsonl"]))
    assert journal_files != []
    journal = Enum.map_join(journal_files, "\n", &File.read!/1)
    refute journal =~ "raw-only-secret"
    assert :ok = Jido.Harness.Session.close(session_id)
    assert {:ok, %{state: state}} = Jido.Harness.Process.await(process.process_id, 2_000)
    assert state in [:cancelled, :exited]
  end

  test "ACP loads an existing provider session through ExMCP" do
    assert {:ok, session_id} =
             Jido.Harness.Session.start(:kimi, %{provider_session_id: "saved-provider-session"})

    assert {:ok, %{provider_session_id: "saved-provider-session"}} = await_ready(session_id)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "loaded")

    assert {:ok, %{status: :completed, text: "fixture-ok"}} =
             Jido.Harness.Session.await(session_id, turn_id, 2_000)
  end

  test "ACP translates permission requests and rejects stale responses" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:kimi, %{})
    assert {:ok, _info} = await_ready(session_id)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "request approval")
    assert {:ok, %{pending_approvals: 1}} = await_approval(session_id)

    assert {:ok, events} = Jido.Harness.Session.replay(session_id, limit: 1_000)
    approval = Enum.find(events, &(&1.type == :approval_requested))
    request_id = approval.request_id
    assert approval.turn_id == turn_id
    assert approval.raw == nil
    assert String.starts_with?(request_id, "request_")
    refute request_id == "99"
    assert :ok = Jido.Harness.Session.respond_approval(session_id, request_id, :approve)
    assert {:error, :not_found} = Jido.Harness.Session.respond_approval(session_id, request_id, :deny)

    assert {:ok, %{status: :completed, text: "approved"} = result} =
             Jido.Harness.Session.await(session_id, turn_id, 2_000)

    approval = Enum.find(result.events, &(&1.type == :approval_requested))
    assert approval.request_id == request_id
    assert approval.raw["id"] == 99
    assert approval.raw["method"] == "session/request_permission"
    assert approval.raw["providerEnvelope"] == %{"trace" => "permission-envelope"}
    assert approval.raw["params"]["providerParameter"] == "permission-parameter"
    assert approval.raw["params"]["toolCall"] == approval.payload["tool_call"]
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

  test "ACP cancellation keeps turn and approval lifecycle in Harness" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:kimi, %{})
    assert {:ok, _info} = await_ready(session_id)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "request approval")
    assert {:ok, %{pending_approvals: 1}} = await_approval(session_id)

    assert :ok = Jido.Harness.Session.interrupt(session_id, turn_id)
    assert {:ok, %{status: :interrupted}} = Jido.Harness.Session.await(session_id, turn_id, 2_000)
    assert {:ok, %{state: :idle, pending_approvals: 0}} = Jido.Harness.Session.info(session_id)
  end

  test "ExMCP rejects a duplicate provider request ID before Harness creates a second approval" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:kimi, %{approval_timeout_ms: 500})
    assert {:ok, _info} = await_ready(session_id)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "duplicate approval")
    assert {:ok, %{pending_approvals: 1}} = await_approval(session_id)

    assert {:ok, events} = Jido.Harness.Session.replay(session_id, limit: 1_000)
    approvals = Enum.filter(events, &(&1.type == :approval_requested))
    assert length(approvals) == 1

    assert :ok = Jido.Harness.Session.respond_approval(session_id, hd(approvals).request_id, :approve)
    assert {:ok, %{status: :completed, text: "denied"}} = Jido.Harness.Session.await(session_id, turn_id, 2_000)
    Process.sleep(50)

    assert {:ok, events} = Jido.Harness.Session.replay(session_id, limit: 1_000)
    approvals = Enum.filter(events, &(&1.type == :approval_requested))
    assert length(approvals) == 1
    assert {:ok, %{state: :idle, pending_approvals: 0}} = Jido.Harness.Session.info(session_id)
  end

  test "ACP accepts launch configuration and rejects unsupported turn options" do
    assert {:ok, configured_id} = Jido.Harness.Session.start(:kimi, %{model: "fixture-model"})
    assert {:ok, _info} = await_ready(configured_id)

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
