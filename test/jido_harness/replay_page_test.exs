defmodule Jido.Harness.ReplayPageTest do
  use ExUnit.Case, async: false
  alias Jido.Harness.{Buffer, Event, EventLog, MemoryHarness, ProcessEvent}
  alias Jido.Harness.ReplayStore.{ETS, File, Memory}

  test "run and session workers return pages and all gap ranges" do
    for kind <- [:run, :session] do
      log = EventLog.open(kind, "page", %{}, {Memory, %{}})

      {_, log} =
        Enum.reduce([1, 4, 6], {Buffer.new(1_000), log}, fn n, {buffer, log} ->
          event = Event.new!(type: :output_text_delta, provider: :test, sequence: n, payload: %{"text" => "value"})
          EventLog.append(buffer, log, event)
        end)

      state = %{MemoryHarness.state() | id: "page", event_log: log}
      worker = if kind == :run, do: Jido.Harness.RunWorker, else: Jido.Harness.SessionWorker
      limits = %{max_events: 2, max_bytes: 10_000}
      assert {:reply, {:ok, page}, state} = worker.handle_call({:replay_page, 0, limits}, nil, state)
      assert Enum.map(page.records, & &1.sequence) == [1, 4]
      assert page.gaps == [%{from: 2, to: 3, reason: :unavailable}]
      assert page.next_cursor == 4
      assert {:reply, {:ok, events}, _} = worker.handle_call({:replay, 0, 100}, nil, state)
      assert Enum.map(events, & &1.sequence) == [1, 3, 4, 5, 6]
    end
  end

  test "managed process pages use the configured adapter and preserve internal live bytes" do
    previous = Application.get_env(:jido_harness, :replay_store)
    driver = Application.get_env(:jido_harness, :process_driver)
    base = Path.join(System.tmp_dir!(), "replay-page-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:jido_harness, :replay_store, previous),
        else: Application.delete_env(:jido_harness, :replay_store)

      if driver,
        do: Application.put_env(:jido_harness, :process_driver, driver),
        else: Application.delete_env(:jido_harness, :process_driver)

      Elixir.File.rm_rf!(base)
    end)

    Application.put_env(:jido_harness, :process_driver, MemoryHarness.Driver)

    for adapter <- [File, Memory, ETS] do
      options = if adapter == File, do: %{journal_dir: base}, else: %{}
      Application.put_env(:jido_harness, :replay_store, {adapter, options})

      {:ok, id} =
        Jido.Harness.Process.start(%{
          executable: "fake",
          metadata: %{test_pid: self()},
          env: %{"API_TOKEN" => "fixture-secret"}
        })

      assert_receive {:memory_driver, worker, exec, os_pid}
      send(worker, {:stdout, os_pid, "fixture-secret"})
      state = :sys.get_state(worker)
      assert {:ok, page} = Jido.Harness.Process.replay_page(id, limit: 10)
      assert Enum.any?(page.records, &match?(%ProcessEvent{type: :stdout, data: "[REDACTED]"}, &1))
      assert page.next_cursor == state.sequence
      assert Enum.any?(Buffer.events(state.buffer), &(&1.data == "fixture-secret"))
      assert {:ok, info} = Jido.Harness.Process.info(id)
      assert info.replay_store.adapter == adapter
      assert info.replay_store.status == :healthy
      assert {:ok, skipped} = Jido.Harness.Process.replay_page(id, max_bytes: 1)
      assert skipped.records == []
      assert skipped.next_cursor == state.sequence
      send(exec, :finish)
      assert {:ok, _} = Jido.Harness.Process.await(id, 1_000)
      assert :ok = Jido.Harness.Process.prune(id)
    end
  end

  test "all public page APIs reject invalid limits" do
    for module <- [Jido.Harness.Process, Jido.Harness.Run, Jido.Harness.Session] do
      assert {:error, %Jido.Harness.Error{category: :validation}} = module.replay_page("missing", max_bytes: 0)
      assert {:error, %Jido.Harness.Error{category: :validation}} = module.replay_page("missing", cursor: -1)
      assert {:error, %Jido.Harness.Error{category: :validation}} = module.replay_page("missing", limit: 10_001)
    end
  end

  test "invalid stored event fields use fallback in page and list APIs" do
    event = Event.new!(type: :output_text_delta, provider: :test, sequence: 1, payload: %{"text" => "safe"})
    record = Jido.Harness.ReplayStore.Record.prepare(event, [])
    invalid = Map.put(record, "type", "unknown_stored_event_type")
    limits = %{max_events: 100, max_bytes: 10_000}
    page = Jido.Harness.ReplayStore.Page.build([invalid], 0, %{latest_sequence: 1, oldest_sequence: 1}, limits)

    for kind <- [:run, :session] do
      log = EventLog.open(kind, "corrupt-event", %{}, {Jido.Harness.ReplayStore.FaultStore, %{page: page}})
      {_, log} = EventLog.append(Buffer.new(10_000), log, event)
      state = %{MemoryHarness.state() | event_log: log}
      worker = if kind == :run, do: Jido.Harness.RunWorker, else: Jido.Harness.SessionWorker
      assert {:reply, {:ok, page}, state} = worker.handle_call({:replay_page, 0, limits}, nil, state)
      assert [%Event{type: :output_text_delta}] = page.records
      assert state.event_log.status == :degraded
      assert {:reply, {:ok, [%Event{type: :output_text_delta}]}, _} = worker.handle_call({:replay, 0, 100}, nil, state)
    end
  end

  test "storage errors do not prevent process cancellation and prune reports cleanup failure" do
    previous = Application.get_env(:jido_harness, :replay_store)
    driver = Application.get_env(:jido_harness, :process_driver)
    Application.put_env(:jido_harness, :process_driver, MemoryHarness.Driver)
    Application.put_env(:jido_harness, :replay_store, {Jido.Harness.ReplayStore.FaultStore, %{operation: :delete}})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:jido_harness, :replay_store, previous),
        else: Application.delete_env(:jido_harness, :replay_store)

      if driver,
        do: Application.put_env(:jido_harness, :process_driver, driver),
        else: Application.delete_env(:jido_harness, :process_driver)
    end)

    assert {:ok, id} = Jido.Harness.Process.start(%{executable: "fake", metadata: %{test_pid: self()}})
    assert_receive {:memory_driver, worker, exec, _}
    assert {:ok, page} = Jido.Harness.Process.replay_page(id)
    assert page.records != []
    assert :ok = Jido.Harness.Process.cancel(id)
    send(exec, :finish)
    assert {:ok, %{state: :cancelled}} = Jido.Harness.Process.await(id, 1_000)
    assert {:error, :eacces} = Jido.Harness.Process.prune(id)
    assert Process.alive?(worker)
    DynamicSupervisor.terminate_child(Jido.Harness.ProcessSupervisor, worker)
  end
end
