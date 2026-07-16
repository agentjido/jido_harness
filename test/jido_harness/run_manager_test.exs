defmodule Jido.Harness.RunManagerTest do
  use ExUnit.Case, async: false

  import Jido.Harness.TestHelpers

  setup context do
    journal_dir = Path.join(System.tmp_dir!(), "jido-harness-run-test-#{System.unique_integer([:positive])}")
    configure_test_provider(Map.put(context, :journal_dir, journal_dir))
    :ok
  end

  test "returns normalized results with ordered replay and one terminal event" do
    assert {:ok, run_id} = Jido.Harness.start(:test, %{prompt: "ok", session_id: "provider-session"})
    assert {:ok, result} = Jido.Harness.await(run_id, 5_000)

    assert result.run_id == run_id
    assert result.provider == :test
    assert result.session_id == "provider-session"
    assert result.status == :completed
    assert result.text == "fixture-ok"
    assert result.usage == %{"input_tokens" => 2, "output_tokens" => 1}
    assert Enum.count(result.events, &Jido.Harness.Event.terminal?/1) == 1

    assert {:ok, replayed} = Jido.Harness.replay(run_id, limit: 100)
    assert Enum.map(replayed, & &1.sequence) == Enum.to_list(1..length(replayed))
    assert Enum.count(replayed, &Jido.Harness.Event.terminal?/1) == 1
    assert List.first(replayed).type == :session_started
    assert List.last(replayed).type == :session_completed

    assert {:ok, stream} = Jido.Harness.stream(run_id, poll_interval_ms: 1)
    assert Enum.map(Enum.to_list(stream), & &1.sequence) == Enum.map(replayed, & &1.sequence)
  end

  test "status exposes smoke readiness and lifecycle capabilities" do
    assert {:ok, status} = Jido.Harness.status(:test)
    assert status.smoke_ready
    assert Jido.Harness.ProviderStatus.ready?(status)
    assert status.capabilities.resume?
    refute status.capabilities.native_cancel?
  end

  test "emits direct run and adapter lifecycle telemetry without request data" do
    owner = self()
    handler = "run-lifecycle-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [
        [:jido, :harness, :run, :start],
        [:jido, :harness, :run, :stop],
        [:jido, :harness, :adapter, :start],
        [:jido, :harness, :adapter, :stop]
      ],
      fn name, measurements, metadata, _config ->
        send(owner, {:lifecycle_telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, run_id} = Jido.Harness.start(:test, %{prompt: "secret prompt"})
    assert {:ok, %{status: :completed}} = Jido.Harness.await(run_id, 5_000)

    for event <- [
          [:jido, :harness, :run, :start],
          [:jido, :harness, :adapter, :start],
          [:jido, :harness, :adapter, :stop],
          [:jido, :harness, :run, :stop]
        ] do
      assert_receive {:lifecycle_telemetry, ^event, measurements, metadata}
      assert metadata.run_id == run_id
      assert metadata.provider == :test
      refute inspect({measurements, metadata}) =~ "secret prompt"
    end
  end

  test "await timeout does not cancel a run" do
    assert {:ok, run_id} = Jido.Harness.start(:test, %{prompt: "slow"})
    assert {:error, :timeout} = Jido.Harness.await(run_id, 10)
    assert {:ok, %{state: :running}} = Jido.Harness.info(run_id)
    assert {:ok, %{status: :completed}} = Jido.Harness.await(run_id, 5_000)
  end

  test "run survives its starting caller" do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(parent, {:started, Jido.Harness.start(:test, %{prompt: "slow"})})
      end)

    assert_receive {:started, {:ok, run_id}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    assert {:ok, %{status: :completed}} = Jido.Harness.await(run_id, 5_000)
  end

  test "an abrupt run-worker crash stops its linked adapter task without retrying" do
    assert {:ok, run_id} = Jido.Harness.start(:test, %{prompt: "wait"})
    [{worker, _value}] = Registry.lookup(Jido.Harness.RunRegistry, run_id)
    %{task: %{pid: adapter_task}} = :sys.get_state(worker)
    worker_monitor = Process.monitor(worker)
    task_monitor = Process.monitor(adapter_task)

    Process.exit(worker, :kill)

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, ^task_monitor, :process, ^adapter_task, :killed}, 1_000
    assert eventually(fn -> Registry.lookup(Jido.Harness.RunRegistry, run_id) == [] end)
  end

  test "an abrupt direct-CLI run-worker crash cancels its owned process" do
    providers = Application.get_env(:jido_harness, :providers, %{})
    Application.put_env(:jido_harness, :providers, Map.put(providers, :owned_cli, Jido.Harness.OwnedCLITestAdapter))
    on_exit(fn -> Application.put_env(:jido_harness, :providers, providers) end)

    assert {:ok, run_id} = Jido.Harness.start(:owned_cli, %{prompt: "wait"})
    process_id = await_owned_process(run_id)
    [{worker, _value}] = Registry.lookup(Jido.Harness.RunRegistry, run_id)
    Process.exit(worker, :kill)

    assert {:ok, %{state: :cancelled}} = Jido.Harness.await_process(process_id, 5_000)
    assert eventually(fn -> Registry.lookup(Jido.Harness.RunRegistry, run_id) == [] end)
  end

  test "fallback cancellation stops the adapter worker and emits one terminal event" do
    assert {:ok, run_id} = Jido.Harness.start(:test, %{prompt: "wait"})
    assert :ok = Jido.Harness.cancel(run_id)
    assert {:ok, result} = Jido.Harness.await(run_id, 5_000)
    assert result.status == :cancelled
    assert Enum.count(result.events, &Jido.Harness.Event.terminal?/1) == 1
    assert List.last(result.events).type == :session_cancelled
  end

  test "run-level runtime and idle timeouts cover SDK-backed adapters" do
    assert {:ok, runtime_id} =
             Jido.Harness.start(:test, %{prompt: "wait", runtime_timeout_ms: 30})

    assert {:ok, runtime_result} = Jido.Harness.await(runtime_id, 5_000)
    assert runtime_result.status == :failed
    assert %Jido.Harness.Error{category: :timeout} = runtime_result.error
    assert List.last(runtime_result.events).type == :session_failed

    assert {:ok, idle_id} =
             Jido.Harness.start(:test, %{prompt: "wait", idle_timeout_ms: 30})

    assert {:ok, idle_result} = Jido.Harness.await(idle_id, 5_000)
    assert idle_result.status == :failed
    assert %Jido.Harness.Error{category: :timeout} = idle_result.error
  end

  test "adapter failures and crashes become normalized failed results" do
    for prompt <- ["fail", "raise"] do
      assert {:ok, run_id} = Jido.Harness.start(:test, %{prompt: prompt})
      assert {:ok, result} = Jido.Harness.await(run_id, 5_000)
      assert result.status == :failed
      assert %Jido.Harness.Error{category: :execution, run_id: ^run_id} = result.error
      assert Enum.count(result.events, &Jido.Harness.Event.terminal?/1) == 1
    end
  end

  test "rejects unsupported normalized and provider-specific options before execution" do
    assert {:error, %Jido.Harness.Error{category: :validation}} =
             Jido.Harness.start(:test, %{prompt: "ok", provider_options: %{unknown: true}})

    original = Application.get_env(:jido_harness, :providers)

    Application.put_env(:jido_harness, :providers, %{
      test: Jido.Harness.TestAdapter,
      limited: Jido.Harness.LimitedTestAdapter
    })

    on_exit(fn -> Application.put_env(:jido_harness, :providers, original) end)

    assert {:error, %Jido.Harness.Error{category: :validation, details: %{field: :model}}} =
             Jido.Harness.start(:limited, %{prompt: "ok", model: "unsupported"})

    before_ids = Jido.Harness.list_runs() |> Enum.map(& &1.run_id) |> MapSet.new()

    assert {:error,
            %Jido.Harness.Error{
              category: :validation,
              provider: :gemini,
              details: %{field: :sandbox_mode, value: :read_only}
            }} = Jido.Harness.start(:gemini, %{prompt: "unsupported", sandbox_mode: :read_only})

    assert {:error,
            %Jido.Harness.Error{
              category: :validation,
              provider: :opencode,
              details: %{field: :approval_mode, value: :auto_edit}
            }} = Jido.Harness.start(:opencode, %{prompt: "unsupported", approval_mode: :auto_edit})

    after_ids = Jido.Harness.list_runs() |> Enum.map(& &1.run_id) |> MapSet.new()
    assert after_ids == before_ids
  end

  defp await_owned_process(run_id, attempts \\ 100)

  defp await_owned_process(_run_id, 0), do: flunk("owned CLI process did not start")

  defp await_owned_process(run_id, attempts) do
    case Enum.find(Jido.Harness.list_processes(), &(Map.get(&1.metadata, :run_id) == run_id)) do
      nil ->
        Process.sleep(10)
        await_owned_process(run_id, attempts - 1)

      info ->
        info.process_id
    end
  end

  defp eventually(function, attempts \\ 100)

  defp eventually(function, attempts) when attempts > 0 do
    if function.() do
      true
    else
      Process.sleep(10)
      eventually(function, attempts - 1)
    end
  end

  defp eventually(_function, 0), do: false
end
