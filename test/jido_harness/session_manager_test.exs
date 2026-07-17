defmodule Jido.Harness.SessionManagerTest do
  use ExUnit.Case, async: false

  import Jido.Harness.TestHelpers

  setup context do
    journal_dir = Path.join(System.tmp_dir!(), "jido-harness-session-test-#{System.unique_integer([:positive])}")
    configure_test_provider(Map.put(context, :journal_dir, journal_dir))
    :ok
  end

  test "runs multiple turns, carries provider identity, and supports replay" do
    assert {:ok, session_id} = Jido.Harness.open_session(:test)
    assert {:ok, %{state: :idle, session_id: ^session_id, transport: :managed}} = await_idle(session_id)

    assert {:ok, first_turn} = Jido.Harness.send_message(session_id, "first")
    assert {:ok, first} = Jido.Harness.await_turn(session_id, first_turn, 5_000)
    assert first.status == :completed
    assert first.text == "fixture-ok"
    assert first.provider_session_id == "fixture-session"

    assert {:ok, %{state: :idle, provider_session_id: "fixture-session"}} = Jido.Harness.info_session(session_id)

    assert {:ok, second_turn} = Jido.Harness.send_message(session_id, "second")
    assert {:ok, second} = Jido.Harness.await_turn(session_id, second_turn, 5_000)
    assert second.provider_session_id == "fixture-session"

    assert {:ok, events} = Jido.Harness.replay_session(session_id, limit: 1_000)
    assert hd(events).type == :session_started
    assert Enum.any?(events, &(&1.type == :session_ready))
    assert Enum.count(events, &(&1.type == :turn_completed)) == 2
    assert Enum.map(events, & &1.sequence) == Enum.to_list(1..length(events))
    assert Enum.all?(events, &(&1.session_id == session_id and is_nil(&1.run_id)))

    assert :ok = Jido.Harness.close_session(session_id)
    assert {:ok, %{state: :closed}} = Jido.Harness.info_session(session_id)
    assert {:ok, events} = Jido.Harness.replay_session(session_id, limit: 1_000)
    assert Enum.count(events, &Jido.Harness.Event.session_terminal?/1) == 1
    assert List.last(events).type == :session_closed
  end

  test "rejects concurrent sends and queues managed follow ups FIFO" do
    assert {:ok, session_id} = Jido.Harness.open_session(:test)
    assert {:ok, _info} = await_idle(session_id)
    assert {:ok, active} = Jido.Harness.send_message(session_id, "slow")
    assert {:error, :busy} = Jido.Harness.send_message(session_id, "not accepted")
    assert {:ok, queued_one} = Jido.Harness.follow_up(session_id, "one")
    assert {:ok, queued_two} = Jido.Harness.follow_up(session_id, "two")

    assert {:ok, %{status: :completed}} = Jido.Harness.await_turn(session_id, active, 5_000)
    assert {:ok, %{status: :completed}} = Jido.Harness.await_turn(session_id, queued_one, 5_000)
    assert {:ok, %{status: :completed}} = Jido.Harness.await_turn(session_id, queued_two, 5_000)

    assert {:ok, events} = Jido.Harness.replay_session(session_id, limit: 1_000)

    completed =
      events
      |> Enum.filter(&(&1.type == :turn_completed))
      |> Enum.map(& &1.turn_id)

    assert completed == [active, queued_one, queued_two]
  end

  test "interrupts a turn without closing the session and await timeout is non-destructive" do
    assert {:ok, session_id} = Jido.Harness.open_session(:test)
    assert {:ok, _info} = await_idle(session_id)
    assert {:ok, turn_id} = Jido.Harness.send_message(session_id, "wait")
    assert {:error, :timeout} = Jido.Harness.await_turn(session_id, turn_id, 10)
    assert {:ok, %{state: :running}} = Jido.Harness.info_session(session_id)
    assert :ok = Jido.Harness.interrupt_turn(session_id)
    assert {:ok, %{status: :interrupted}} = Jido.Harness.await_turn(session_id, turn_id, 5_000)
    assert {:ok, %{state: :idle}} = Jido.Harness.info_session(session_id)
    assert {:ok, _turn_id} = Jido.Harness.send_message(session_id, "wait")
    assert {:error, %Jido.Harness.Error{details: %{capability: :steer}}} = Jido.Harness.steer(session_id, "x")
  end

  test "survives its opening caller and enforces idle timeout" do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(parent, {:opened, Jido.Harness.open_session(:test, %{session_idle_timeout_ms: 50})})
      end)

    assert_receive {:opened, {:ok, session_id}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    assert eventually(fn -> match?({:ok, %{state: :closed}}, Jido.Harness.info_session(session_id)) end)
  end

  test "configures managed future turns and prunes terminal sessions" do
    assert {:ok, session_id} = Jido.Harness.open_session(:test)
    assert {:ok, _info} = await_idle(session_id)
    assert :ok = Jido.Harness.configure_session(session_id, %{"model" => "fixture-model"})
    assert :ok = Jido.Harness.close_session(session_id)
    assert :ok = Jido.Harness.prune_session(session_id)
    assert {:error, :not_found} = Jido.Harness.info_session(session_id)
  end

  test "rejects unsupported rich turn inputs before provider dispatch" do
    assert {:ok, session_id} = Jido.Harness.open_session(:test)
    assert {:ok, _info} = await_idle(session_id)

    assert {:error, %Jido.Harness.Error{details: %{capability: :structured_output}}} =
             Jido.Harness.send_message(session_id, %{prompt: "hello", output_schema: %{"type" => "string"}})

    assert {:error, %Jido.Harness.Error{details: %{capability: :multimodal}}} =
             Jido.Harness.send_message(session_id, %{
               content: [%{"type" => "image", "url" => "https://example.invalid/image.png"}]
             })

    assert {:error, %Jido.Harness.Error{message: "unknown turn provider option"}} =
             Jido.Harness.send_message(session_id, %{prompt: "hello", provider_options: %{unknown: true}})

    assert {:ok, %{state: :idle}} = Jido.Harness.info_session(session_id)
  end

  test "drops late events after a turn terminal" do
    assert {:ok, session_id} = Jido.Harness.open_session(:test)
    assert {:ok, _info} = await_idle(session_id)
    assert {:ok, turn_id} = Jido.Harness.send_message(session_id, "hello")
    assert {:ok, %{status: :completed}} = Jido.Harness.await_turn(session_id, turn_id, 5_000)

    [{worker, _value}] = Registry.lookup(Jido.Harness.SessionRegistry, session_id)

    send(
      worker,
      {:session_adapter_event,
       Jido.Harness.Event.new!(
         type: :turn_completed,
         provider: :test,
         turn_id: turn_id,
         payload: %{"duplicate" => true}
       )}
    )

    Process.sleep(10)
    assert {:ok, events} = Jido.Harness.replay_session(session_id, limit: 1_000)
    assert Enum.count(events, &(&1.type == :turn_completed and &1.turn_id == turn_id)) == 1
  end

  test "closing an active session terminates active and queued turns without idle churn" do
    assert {:ok, session_id} = Jido.Harness.open_session(:test)
    assert {:ok, _info} = await_idle(session_id)
    assert {:ok, active_id} = Jido.Harness.send_message(session_id, "wait")
    assert {:ok, queued_id} = Jido.Harness.follow_up(session_id, "never starts")
    assert :ok = Jido.Harness.close_session(session_id)

    assert {:ok, %{status: :interrupted}} = Jido.Harness.await_turn(session_id, active_id, 2_000)
    assert {:ok, %{status: :interrupted}} = Jido.Harness.await_turn(session_id, queued_id, 2_000)
    assert {:ok, events} = Jido.Harness.replay_session(session_id, limit: 1_000)

    first_interrupted = Enum.find_index(events, &(&1.type == :turn_interrupted))
    assert first_interrupted
    refute events |> Enum.drop(first_interrupted) |> Enum.any?(&(&1.type == :session_idle))
    assert List.last(events).type == :session_closed
  end

  test "a transport exit produces a retained failed session instead of crashing its worker" do
    assert {:ok, session_id} = Jido.Harness.open_session(:test)
    assert {:ok, _info} = await_idle(session_id)
    [{worker, _value}] = Registry.lookup(Jido.Harness.SessionRegistry, session_id)
    handle = :sys.get_state(worker).handle
    Process.exit(handle, :kill)

    assert match?({:error, _reason}, Jido.Harness.send_message(session_id, "after exit"))
    assert eventually(fn -> match?({:ok, %{state: :failed}}, Jido.Harness.info_session(session_id)) end)
    assert Process.alive?(worker)

    assert {:ok, events} = Jido.Harness.replay_session(session_id, limit: 1_000)
    assert Enum.count(events, &Jido.Harness.Event.session_terminal?/1) == 1
    assert List.last(events).type == :session_failed
  end

  test "rejects environment overrides when an experimental transport cannot apply them" do
    Application.put_env(:jido_harness, :providers, %{codex: Jido.Harness.Adapters.Codex})
    Application.put_env(:jido_harness, :provider_config, %{codex: %{}})

    assert {:error,
            %Jido.Harness.Error{
              provider: :codex,
              message: "session transport does not support environment overrides",
              details: %{transport: :app_server, field: :env}
            }} =
             Jido.Harness.open_session(:codex, %{
               transport: :app_server,
               env: %{"OPENAI_API_KEY" => "must-not-be-ignored"}
             })
  end

  test "validates malformed session and turn option lists without raising" do
    assert {:error, %Jido.Harness.Error{message: "options must be a keyword list"}} =
             Jido.Harness.open_session(:test, %{}, [:invalid])

    assert {:ok, session_id} = Jido.Harness.open_session(:test)
    assert {:ok, _info} = await_idle(session_id)

    assert {:error, %Jido.Harness.Error{message: "options must be a keyword list"}} =
             Jido.Harness.send_message(session_id, "hello", [:invalid])

    assert {:error, %Jido.Harness.Error{message: "await timeout must be :infinity or a non-negative integer"}} =
             Jido.Harness.await_turn(session_id, "missing", "later")
  end

  defp await_idle(session_id, attempts \\ 100)

  defp await_idle(_session_id, 0), do: {:error, :timeout}

  defp await_idle(session_id, attempts) do
    case Jido.Harness.info_session(session_id) do
      {:ok, %{state: :idle}} = result ->
        result

      _ ->
        Process.sleep(10)
        await_idle(session_id, attempts - 1)
    end
  end

  defp eventually(function, attempts \\ 100)
  defp eventually(_function, 0), do: false

  defp eventually(function, attempts) do
    if function.() do
      true
    else
      Process.sleep(10)
      eventually(function, attempts - 1)
    end
  end
end
