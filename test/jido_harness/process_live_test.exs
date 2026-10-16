defmodule Jido.Harness.ProcessLiveTest do
  use ExUnit.Case, async: false
  alias Jido.Harness.{MemoryHarness, ProcessManager}

  setup do
    original = Application.get_env(:jido_harness, :process_driver)
    Application.put_env(:jido_harness, :process_driver, MemoryHarness.Driver)
    dir = Path.join(System.tmp_dir!(), "harness-live-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if original,
        do: Application.put_env(:jido_harness, :process_driver, original),
        else: Application.delete_env(:jido_harness, :process_driver)

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "live delivery preserves wire bytes, blocks without polling, and never reads the journal", %{dir: dir} do
    {id, worker, exec, os_pid} = start_memory_process(dir)
    parent = self()
    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:jido, :harness, :journal, :replay],
        fn _, _, _, _ -> send(parent, :disk_replay) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, stream} = ProcessManager.live_stream_process(id)
    reader = Task.async(fn -> Enum.to_list(stream) end)
    MemoryHarness.await(fn -> :sys.get_state(worker).output_waiter != nil end)
    assert {:ok, %{state: :running}} = ProcessManager.info_process(id)
    assert :ok = ProcessManager.send_input(id, "input")
    assert {:error, :reader_busy} = GenServer.call(worker, {:live_output, 1, 100})

    wire = "{\"token\":\"test-secret-1234\"}\n"
    send(worker, {:stdout, os_pid, wire})
    send(exec, :finish)
    events = Task.await(reader)
    assert Enum.map(events, & &1.type) == [:started, :stdout, :exited]
    assert Enum.at(events, 1).data == wire
    refute_received :disk_replay

    assert {:ok, persisted} = ProcessManager.replay_process(id)
    refute Enum.at(persisted, 1).data =~ "test-secret-1234"
    assert_receive :disk_replay
    assert :ok = ProcessManager.prune_process(id)
  end

  test "dead live callers release their monitor and pending read", %{dir: dir} do
    {_id, worker, _exec, _os_pid} = start_memory_process(dir)
    caller = spawn(fn -> GenServer.call(worker, {:live_output, 1, 100}, :infinity) end)
    MemoryHarness.await(fn -> :sys.get_state(worker).output_waiter != nil end)
    Process.exit(caller, :kill)
    MemoryHarness.await(fn -> :sys.get_state(worker).output_waiter == nil end)
    refute {:process, caller} in elem(Process.info(worker, :monitors), 1)
  end

  test "a slow live reader gets an explicit gap when memory retention is exceeded", %{dir: dir} do
    {id, worker, _exec, os_pid} = start_memory_process(dir, 500)
    send(worker, {:stdout, os_pid, String.duplicate("x", 2_000)})
    assert {:ok, %{output_cursor: 2}} = ProcessManager.info_process(id)
    assert {:ok, stream} = ProcessManager.live_stream_process(id)
    assert [%{type: :replay_gap, data: %{"available_from" => 3}}] = Enum.to_list(stream)
  end

  test "a normal worker exit during a call returns not_found" do
    id = "stopping-#{System.unique_integer([:positive])}"
    parent = self()

    spawn(fn ->
      {:ok, _} = Registry.register(Jido.Harness.ProcessRegistry, id, nil)
      send(parent, :stopping_worker_ready)

      receive do
        {:"$gen_call", _from, :info} -> :ok
      end
    end)

    assert_receive :stopping_worker_ready
    assert {:error, :not_found} = ProcessManager.info_process(id)
  end

  test "process memory defaults can size ACP output and per-process retention takes priority", %{dir: dir} do
    original = Application.get_env(:jido_harness, :process_manager)
    Application.put_env(:jido_harness, :process_manager, Map.put(Map.new(original || %{}), :memory_bytes, 1_024))

    on_exit(fn ->
      if original,
        do: Application.put_env(:jido_harness, :process_manager, original),
        else: Application.delete_env(:jido_harness, :process_manager)
    end)

    {_id, worker, _exec, _os_pid} = start_memory_process(dir, nil)
    assert :sys.get_state(worker).buffer.max_bytes == 1_024
    {_id, worker, _exec, _os_pid} = start_memory_process(dir, 2_048)
    assert :sys.get_state(worker).buffer.max_bytes == 2_048
  end

  defp start_memory_process(dir, memory_bytes \\ 65_536) do
    retention = if memory_bytes, do: %{journal_dir: dir, memory_bytes: memory_bytes}, else: %{journal_dir: dir}

    assert {:ok, id} =
             ProcessManager.start_process(%{
               executable: System.find_executable("elixir"),
               env: %{"TEST_SECRET" => "test-secret-1234"},
               metadata: %{test_pid: self()},
               retention: retention
             })

    assert_receive {:memory_driver, worker, exec, os_pid}

    on_exit(fn ->
      if Process.alive?(worker), do: DynamicSupervisor.terminate_child(Jido.Harness.ProcessSupervisor, worker)
    end)

    {id, worker, exec, os_pid}
  end
end
