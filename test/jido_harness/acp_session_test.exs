defmodule Jido.Harness.ACPSessionTest do
  use ExUnit.Case, async: false

  setup do
    providers = Application.get_env(:jido_harness, :providers)
    config = Application.get_env(:jido_harness, :provider_config)
    fixture = Jido.Harness.TestHelpers.fixture_path("fake_acp_cli.py")
    journal_dir = Path.join(System.tmp_dir!(), "jido-harness-acp-#{System.unique_integer([:positive])}")

    Application.put_env(:jido_harness, :providers, %{
      kimi: Jido.Harness.Adapters.Kimi,
      claude: Jido.Harness.Adapters.Claude
    })

    Application.put_env(:jido_harness, :provider_config, %{
      kimi: %{acp_path: fixture, retention: %{journal_dir: journal_dir}},
      claude: %{acp_path: fixture, retention: %{journal_dir: journal_dir}}
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

  test "Arbor ACP correlates fragmented responses while Harness owns process and event identity", %{
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

  test "a slow initialize handshake does not block another session" do
    assert {:ok, slow} = Jido.Harness.Session.start(:kimi, %{env: %{"HARNESS_FIXTURE_INITIALIZE_DELAY" => "1.5"}})
    assert {:ok, fast} = Jido.Harness.Session.start(:kimi, %{})
    assert {:ok, _info} = await_ready(fast, 50)

    transport =
      Jido.Harness.SessionTransportSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.map(fn {_, pid, _, _} -> pid end)
      |> Enum.find(fn pid -> :sys.get_state(pid).context.session_id == slow end)

    assert :sys.get_state(transport).initialize_from != nil
    assert :ok = Jido.Harness.Session.close(slow)
    assert {:ok, _info} = Jido.Harness.Session.info(fast)
  end

  test "ACP loads an existing provider session through Arbor ACP" do
    assert {:ok, session_id} =
             Jido.Harness.Session.start(:kimi, %{provider_session_id: "saved-provider-session"})

    assert {:ok, %{provider_session_id: "saved-provider-session"}} = await_ready(session_id)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "loaded")

    assert {:ok, %{status: :completed, text: "fixture-ok"}} =
             Jido.Harness.Session.await(session_id, turn_id, 2_000)
  end

  test "ACP forks an existing provider session into a new one through Arbor ACP" do
    assert {:ok, session_id} =
             Jido.Harness.Session.start(:kimi, %{fork_session_id: "saved-provider-session"})

    assert {:ok, %{provider_session_id: "fork-of-saved-provider-session"}} = await_ready(session_id)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "forked")

    assert {:ok, %{status: :completed, text: "fixture-ok"}} =
             Jido.Harness.Session.await(session_id, turn_id, 2_000)
  end

  test "a fork fails to open when the ACP agent does not advertise forking" do
    assert {:ok, session_id} =
             Jido.Harness.Session.start(:kimi, %{
               fork_session_id: "saved-provider-session",
               env: %{"HARNESS_FIXTURE_NO_FORK" => "1"}
             })

    assert {:ok, %{state: :failed}} = await_state(session_id, :failed)
  end

  test "input steers the running turn of an agent that advertises steering" do
    assert {:ok, session_id} =
             Jido.Harness.Session.start(:kimi, %{env: %{"HARNESS_FIXTURE_STEERING" => "1"}})

    assert {:ok, _info} = await_state(session_id, :idle)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "wait")
    assert eventually(fn -> match?({:ok, %{state: :running}}, Jido.Harness.Session.info(session_id)) end)

    assert {:ok, ^turn_id} = Jido.Harness.Session.steer(session_id, "use the other file")

    assert {:ok, %{status: :completed, text: "steered: use the other file"}} =
             Jido.Harness.Session.await(session_id, turn_id, 2_000)

    # Once the turn has ended there is nothing to steer, and the agent starts no turn of its own
    assert {:error, :no_active_turn} = Jido.Harness.Session.steer(session_id, "late")
    assert {:ok, %{state: :idle}} = Jido.Harness.Session.info(session_id)
  end

  @tag :capture_log
  test "steering that starts an untracked turn fails the session and stops the provider" do
    assert {:ok, session_id} =
             Jido.Harness.Session.start(:claude, %{
               env: %{"HARNESS_FIXTURE_STEERING" => "1", "HARNESS_FIXTURE_STEERING_NEW_TURN" => "1"}
             })

    assert {:ok, _info} = await_state(session_id, :idle)

    process = Enum.find(Jido.Harness.Process.list(), &(&1.metadata[:session_id] == session_id))
    assert %{state: :running} = process
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "wait")
    steering = Task.async(fn -> Jido.Harness.Session.steer(session_id, "continue") end)

    assert {:ok, %{status: :completed, text: "original turn finished"}} =
             Jido.Harness.Session.await(session_id, turn_id, 2_000)

    assert :ok = Jido.Harness.Session.configure(session_id, %{model: "start-untracked-turn"})
    assert {:error, {:steering_failed, :unexpected_new_turn}} = Task.await(steering, 2_000)
    assert {:ok, %{state: :failed, active_turn_id: nil}} = await_state(session_id, :failed)
    assert {:ok, %{state: state}} = Jido.Harness.Process.await(process.process_id, 2_000)
    assert state in [:cancelled, :exited]
    assert {:error, :closed} = Jido.Harness.Session.send_message(session_id, "next")
  end

  test "steering input that cannot be sent is refused and the session goes on" do
    assert {:ok, session_id} =
             Jido.Harness.Session.start(:kimi, %{env: %{"HARNESS_FIXTURE_STEERING" => "1"}})

    assert {:ok, _info} = await_state(session_id, :idle)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "wait")
    assert eventually(fn -> match?({:ok, %{state: :running}}, Jido.Harness.Session.info(session_id)) end)

    # Not UTF-8: it cannot be written as JSON
    assert {:error, {:steering_failed, {:invalid_request, _message}}} =
             Jido.Harness.Session.steer(session_id, <<0xFF, "x">>)

    # An attachment is checked as for any turn
    assert {:error, %Jido.Harness.Error{details: %{path: _path}}} =
             Jido.Harness.Session.steer(session_id, %{prompt: "hi", attachments: ["/nope/missing"]})

    assert {:ok, ^turn_id} = Jido.Harness.Session.steer(session_id, "use the other file")

    assert {:ok, %{status: :completed, text: "steered: use the other file"}} =
             Jido.Harness.Session.await(session_id, turn_id, 2_000)

    assert {:ok, next} = Jido.Harness.Session.send_message(session_id, "again")
    assert {:ok, %{status: :completed}} = Jido.Harness.Session.await(session_id, next, 2_000)
  end

  @tag :capture_log
  test "a steering timeout fails the session before a late reply can start an untracked turn" do
    assert {:ok, session_id} =
             Jido.Harness.Session.start(:claude, %{
               env: %{"HARNESS_FIXTURE_STEERING" => "1", "HARNESS_FIXTURE_STEERING_NEW_TURN" => "1"}
             })

    assert {:ok, _info} = await_state(session_id, :idle)
    process = Enum.find(Jido.Harness.Process.list(), &(&1.metadata[:session_id] == session_id))
    assert %{state: :running} = process
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "wait")
    steering = Task.async(fn -> Jido.Harness.Session.steer(session_id, "continue") end)

    # The fixture holds the reply until another configuration request. Once
    # it times out, the provider must stop before it can send startedNewTurn.
    assert {:ok, %{status: :completed}} = Jido.Harness.Session.await(session_id, turn_id, 2_000)
    assert {:error, {:steering_failed, :timeout}} = Task.await(steering, 12_000)
    assert {:ok, %{state: :failed, active_turn_id: nil}} = await_state(session_id, :failed)
    assert {:ok, %{state: state}} = Jido.Harness.Process.await(process.process_id, 2_000)
    assert state in [:cancelled, :exited]
    assert {:error, :closed} = Jido.Harness.Session.send_message(session_id, "next")
  end

  test "steering over the frame limit is refused before dispatch and the turn remains usable" do
    assert {:ok, session_id} =
             Jido.Harness.Session.start(:kimi, %{env: %{"HARNESS_FIXTURE_STEERING" => "1"}})

    assert {:ok, _info} = await_state(session_id, :idle)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "wait")
    limit = Jido.Harness.SessionAdapters.ACP.ArborACPTransport.max_frame_bytes()

    assert {:error, {:steering_failed, :frame_too_large}} =
             Jido.Harness.Session.steer(session_id, String.duplicate("x", limit))

    assert {:ok, ^turn_id} = Jido.Harness.Session.steer(session_id, "small input")

    assert {:ok, %{status: :completed, text: "steered: small input"}} =
             Jido.Harness.Session.await(session_id, turn_id, 2_000)
  end

  test "invalid optional steering metadata leaves the agent usable without steering" do
    for metadata <- [true, "unsupported", [], nil, %{"supported" => "true"}] do
      assert {:ok, session_id} =
               Jido.Harness.Session.start(:kimi, %{
                 env: %{"HARNESS_FIXTURE_STEERING_META" => Jason.encode!(metadata)}
               })

      assert {:ok, _info} = await_ready(session_id)
      assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "wait")

      assert {:error, %Jido.Harness.Error{details: %{capability: :steer}}} =
               Jido.Harness.Session.steer(session_id, "unsupported")

      assert :ok = Jido.Harness.Session.interrupt(session_id)
      assert {:ok, %{status: :interrupted}} = Jido.Harness.Session.await(session_id, turn_id, 2_000)
      assert :ok = Jido.Harness.Session.close(session_id)
    end
  end

  test "an agent that does not advertise steering refuses it" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:kimi, %{})
    assert {:ok, _info} = await_state(session_id, :idle)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "wait")
    assert eventually(fn -> match?({:ok, %{state: :running}}, Jido.Harness.Session.info(session_id)) end)

    assert {:error, %Jido.Harness.Error{details: %{capability: :steer}}} =
             Jido.Harness.Session.steer(session_id, "x")

    assert :ok = Jido.Harness.Session.interrupt(session_id)
    assert {:ok, %{status: :interrupted}} = Jido.Harness.Session.await(session_id, turn_id, 2_000)
  end

  test "a request cannot both resume and fork a session" do
    assert {:error, %Jido.Harness.Error{}} =
             Jido.Harness.Session.start(:kimi, %{
               provider_session_id: "saved-provider-session",
               fork_session_id: "saved-provider-session"
             })
  end

  test "turn completion waits for queued Arbor ACP update callbacks" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:kimi, %{})
    assert {:ok, _info} = await_ready(session_id)

    [{worker, _value}] = Registry.lookup(Jido.Harness.SessionRegistry, session_id)
    transport = :sys.get_state(worker).handle
    client = :sys.get_state(transport).client
    handler = :sys.get_state(client).handler_pid
    assert :ok = :sys.suspend(handler)

    on_exit(fn ->
      if Process.alive?(handler), do: :sys.resume(handler)
    end)

    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "fixture")

    assert eventually(fn ->
             match?(%{pending_prompt_result: {^turn_id, _result}}, :sys.get_state(transport))
           end)

    assert :ok = :sys.resume(handler)

    assert {:ok, result} = Jido.Harness.Session.await(session_id, turn_id, 2_000)
    assert result.status == :completed
    assert result.text == "fixture-ok"
    assert result.usage == %{"size" => 10, "used" => 3}
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

  test "a native background permission between turns reaches host policy and returns to idle" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:claude, %{env: %{"HARNESS_FIXTURE_IDLE_PERMISSION" => "1"}})
    assert {:ok, _info} = await_ready(session_id)
    assert :ok = Jido.Harness.Session.configure(session_id, %{model: "background-approval"})
    assert {:ok, %{pending_approvals: 1}} = await_approval(session_id)
    assert {:ok, events} = Jido.Harness.Session.replay(session_id)
    assert %{turn_id: nil} = approval = Enum.find(events, &(&1.type == :approval_requested))
    refute Enum.any?(events, &(&1.payload["kind"] == "stale_approval_denied"))
    assert :ok = Jido.Harness.Session.respond_approval(session_id, approval.request_id, :approve)
    assert {:ok, %{state: :idle, pending_approvals: 0}} = Jido.Harness.Session.info(session_id)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "continue")
    assert {:ok, %{status: :completed}} = Jido.Harness.Session.await(session_id, turn_id, 2_000)
  end

  test "a background approval timeout settles back to idle" do
    assert {:ok, session_id} =
             Jido.Harness.Session.start(:claude, %{
               approval_timeout_ms: 100,
               env: %{"HARNESS_FIXTURE_IDLE_PERMISSION" => "1"}
             })

    assert {:ok, _info} = await_ready(session_id)
    assert :ok = Jido.Harness.Session.configure(session_id, %{model: "background-approval"})

    assert eventually(fn ->
             {:ok, events} = Jido.Harness.Session.replay(session_id)
             Enum.any?(events, &(&1.type == :approval_resolved and &1.payload["reason"] == "timeout"))
           end)

    assert {:ok, %{state: :idle, pending_approvals: 0}} = Jido.Harness.Session.info(session_id)
  end

  test "closing an idle session denies its pending background permission" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:claude, %{env: %{"HARNESS_FIXTURE_IDLE_PERMISSION" => "1"}})
    assert {:ok, _info} = await_ready(session_id)
    assert :ok = Jido.Harness.Session.configure(session_id, %{model: "background-approval"})
    assert {:ok, %{pending_approvals: 1}} = await_approval(session_id)
    assert :ok = Jido.Harness.Session.close(session_id)
    assert {:ok, %{state: :closed, pending_approvals: 0}} = Jido.Harness.Session.info(session_id)
    assert {:ok, events} = Jido.Harness.Session.replay(session_id)
    assert Enum.any?(events, &(&1.type == :approval_resolved and &1.payload["decision"] == "deny"))
  end

  test "an approval explicitly tied to a completed turn is still denied" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:kimi)
    assert {:ok, _info} = await_ready(session_id)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "done")
    assert {:ok, %{status: :completed}} = Jido.Harness.Session.await(session_id, turn_id, 2_000)
    [{worker, _}] = Registry.lookup(Jido.Harness.SessionRegistry, session_id)

    send(
      worker,
      {:session_adapter_event,
       Jido.Harness.Event.new!(
         type: :approval_requested,
         provider: :kimi,
         turn_id: turn_id,
         request_id: "stale-request",
         payload: %{}
       )}
    )

    assert {:ok, %{state: :idle, pending_approvals: 0}} = Jido.Harness.Session.info(session_id)
    assert {:ok, events} = Jido.Harness.Session.replay(session_id)
    assert Enum.any?(events, &(&1.payload["kind"] == "stale_approval_denied"))
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

  test "Arbor ACP rejects a duplicate provider request ID before Harness creates a second approval" do
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

  defp await_state(session_id, state, attempts \\ 100)
  defp await_state(_session_id, _state, 0), do: {:error, :timeout}

  defp await_state(session_id, state, attempts) do
    case Jido.Harness.Session.info(session_id) do
      {:ok, %{state: ^state}} = result ->
        result

      _ ->
        Process.sleep(20)
        await_state(session_id, state, attempts - 1)
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

  defp eventually(condition, attempts \\ 100)
  defp eventually(_condition, 0), do: false

  defp eventually(condition, attempts) do
    if condition.() do
      true
    else
      Process.sleep(10)
      eventually(condition, attempts - 1)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:jido_harness, key)
  defp restore(key, value), do: Application.put_env(:jido_harness, key, value)
end
