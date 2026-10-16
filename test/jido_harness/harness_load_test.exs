defmodule Jido.Harness.HarnessLoadTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.{Buffer, Event, EventLog, MemoryHarness, ProcessEvent, Redaction, TextTail, Waiters}
  alias Jido.Harness.SessionAdapters.ACP.{ExMCPTransport, FrameBuffer}
  alias ExMCPTransport.Bridge

  @moduletag :load
  @moduletag timeout: 120_000

  test "fragmented frames and text deltas have bounded work as retained text grows" do
    sizes = [16_384, 65_536, load_size()]

    measurements =
      for size <- sizes do
        input = String.duplicate("x", size)

        {frame_stats, {frames, buffer}} =
          measure(fn ->
            buffer =
              for <<byte <- input>>, reduce: %FrameBuffer{} do
                buffer ->
                  {:ok, [], buffer} = FrameBuffer.feed(buffer, <<byte>>, size)
                  buffer
              end

            {:ok, frames, buffer} = FrameBuffer.feed(buffer, "\n", size)
            {frames, buffer}
          end)

        assert frames == [input]
        assert buffer.bytes == 0

        {tail_stats, tail} =
          measure(fn ->
            for <<byte <- input>>, reduce: TextTail.new(65_536), do: (tail -> TextTail.append(tail, <<byte>>))
          end)

        assert TextTail.text(tail) == String.duplicate("x", min(size, 65_536))
        assert tail.bytes <= 65_536
        # Reduction counts test work, without a machine-dependent time threshold.
        assert frame_stats.reductions < size * 120
        assert tail_stats.reductions < size * 120
        report(:fragmentation, %{bytes: size, frame: frame_stats, text_tail: tail_stats})
        {size, frame_stats, tail_stats}
      end

    [{small, frame_small, tail_small} | _] = measurements
    {large, frame_large, tail_large} = List.last(measurements)
    assert frame_large.reductions / large < 2 * frame_small.reductions / small
    assert tail_large.reductions / large < 6 * tail_small.reductions / small
  end

  test "a burst of frames pauses the reader and drains in order with bounded bridge state" do
    bridge =
      start_supervised!(
        {Bridge,
         [
           process_manager: MemoryHarness.ProcessManager,
           process_owner: self(),
           process_spec: %{env: %{}},
           listener: self()
         ]}
      )

    assert_receive {:memory_reader, reader}
    count = 5_000
    padding = String.duplicate("x", 1_024)
    data = for n <- 1..count, into: "", do: "#{n}:#{padding}\n"

    event = %ProcessEvent{
      process_id: "memory",
      sequence: 1,
      timestamp: "2026-10-16T00:00:00Z",
      type: :stdout,
      data: data
    }

    send(reader, {:events, [event]})
    MemoryHarness.await(fn -> :sys.get_state(bridge).reader_ack != nil end)
    before = :sys.get_state(bridge)
    assert before.frame_bytes <= before.buffer_limit
    assert elem(Process.info(bridge, :message_queue_len), 1) <= 1
    assert Bridge.connected?(bridge)
    assert :ok = Bridge.send_message(bridge, "control")

    {stats, :ok} =
      measure(fn ->
        for n <- 1..count do
          assert {:ok, frame} = Bridge.receive_message(bridge)
          assert frame == "#{n}:#{padding}"
        end

        :ok
      end)

    after_drain = :sys.get_state(bridge)
    assert after_drain.frame_bytes == 0
    assert after_drain.reader_ack == nil
    assert :queue.is_empty(after_drain.frames)

    report(
      :frame_burst,
      Map.merge(stats, %{frames: count, peak_queued_bytes: before.frame_bytes, queue_limit: before.buffer_limit})
    )

    assert :ok = Bridge.close(bridge)
  end

  test "closing a paused reader releases the reader task" do
    bridge =
      start_supervised!(
        {Bridge,
         [
           process_manager: MemoryHarness.ProcessManager,
           process_owner: self(),
           process_spec: %{env: %{}},
           listener: self()
         ]}
      )

    assert_receive {:memory_reader, reader}

    event = %ProcessEvent{
      process_id: "memory",
      sequence: 1,
      timestamp: "2026-10-16T00:00:00Z",
      type: :stdout,
      data: String.duplicate("frame\n", 50_000)
    }

    send(reader, {:events, [event]})
    MemoryHarness.await(fn -> :sys.get_state(bridge).reader_ack != nil end)
    monitor = Process.monitor(reader)
    assert :ok = Bridge.close(bridge)
    assert_receive {:DOWN, ^monitor, :process, ^reader, _reason}, 2_000
  end

  test "long sessions retain a fixed result and event budget" do
    turns = 2_000

    {stats, state} =
      measure(fn ->
        Enum.reduce(1..turns, MemoryHarness.state(%{max_retained_turns: 32, max_result_bytes: 65_536}), fn n, state ->
          state = MemoryHarness.finish_turn(state, "turn-#{n}")
          assert map_size(state.results) <= 32
          assert state.result_bytes <= 65_536
          assert state.buffer.bytes <= state.buffer.max_bytes
          assert MapSet.size(state.known_turns) == map_size(state.results)
          state
        end)
      end)

    assert Map.has_key?(state.results, "turn-#{turns}")
    assert length(Buffer.events(state.buffer)) < turns

    report(
      :session_history,
      Map.merge(stats, %{
        turns: turns,
        retained_turns: map_size(state.results),
        result_bytes: state.result_bytes,
        buffer_bytes: state.buffer.bytes
      })
    )
  end

  test "waiter cancellation and replies scale with the affected callers" do
    for size <- [1_000, 10_000] do
      refs = for _ <- 1..size, do: make_ref()

      {stats, waiters} =
        measure(fn ->
          waiters = Enum.reduce(refs, %{}, &Waiters.add(&2, &1, {self(), &1}, &1))
          Enum.reduce(refs, waiters, fn ref, waiters -> Waiters.drop_monitor(waiters, waiters[ref].monitor) end)
        end)

      assert waiters == %{}
      assert stats.reductions < size * 1_000
      report(:waiter_churn, Map.put(stats, :callers, size))
    end

    refute {:process, self()} in elem(Process.info(self(), :monitors), 1)
  end

  test "event persistence bounds memory and removes secrets and raw payloads" do
    dir = Path.join(System.tmp_dir!(), "harness-pipeline-load-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    secrets = Redaction.prepare(["load-secret-value"])

    for bytes <- [1_024, 16_384] do
      journal =
        EventLog.open(:run, "pipeline-#{bytes}", %{
          journal_dir: dir,
          disk_limit_bytes: 64_000_000,
          segment_bytes: 262_144
        })

      text = String.duplicate("x", bytes) <> " load-secret-value"

      {stats, {buffer, journal}} =
        measure(fn ->
          Enum.reduce(1..1_000, {Buffer.new(65_536), journal}, fn sequence, {buffer, journal} ->
            event =
              Event.new!(
                type: :output_text_delta,
                provider: :test,
                sequence: sequence,
                payload: %{"text" => text, "nested" => [%{"authorization" => "private"}]},
                raw: text
              )

            EventLog.append(buffer, journal, event, secrets)
          end)
        end)

      assert buffer.bytes <= buffer.max_bytes
      assert List.last(Buffer.events(buffer)).raw == text
      {page, journal} = EventLog.replay(journal, 999, 1)
      records = page.records
      assert [%{"sequence" => 1_000, "raw" => nil, "payload" => payload}] = records
      refute payload["text"] =~ "load-secret-value"
      assert payload["nested"] == [%{"authorization" => "[REDACTED]"}]
      assert journal.status == :healthy
      report(:event_pipeline, Map.merge(stats, %{events: 1_000, payload_bytes: bytes, retained_bytes: buffer.bytes}))
    end
  end

  test "live handoff delivers sustained output without journal replay" do
    original = Application.get_env(:jido_harness, :process_driver)
    Application.put_env(:jido_harness, :process_driver, MemoryHarness.Driver)
    dir = Path.join(System.tmp_dir!(), "harness-live-load-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if original,
        do: Application.put_env(:jido_harness, :process_driver, original),
        else: Application.delete_env(:jido_harness, :process_driver)

      File.rm_rf!(dir)
    end)

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

    {:ok, id} =
      Jido.Harness.ProcessManager.start_process(%{
        executable: System.find_executable("elixir"),
        metadata: %{test_pid: self()},
        retention: %{journal_dir: dir, memory_bytes: 65_536}
      })

    assert_receive {:memory_driver, worker, exec, os_pid}

    on_exit(fn ->
      if Process.alive?(worker), do: DynamicSupervisor.terminate_child(Jido.Harness.ProcessSupervisor, worker)
    end)

    {:ok, stream} = Jido.Harness.ProcessManager.live_stream_process(id)

    reader =
      Task.async(fn ->
        Enum.reduce(stream, 0, fn event, previous ->
          assert event.sequence == previous + 1
          if rem(event.sequence, 100) == 1, do: send(parent, {:live_received, event.sequence})
          event.sequence
        end)
      end)

    assert_receive {:live_received, 1}
    count = 3_000

    {stats, :ok} =
      measure(fn ->
        for batch <- 1..div(count, 100) do
          for n <- 1..100, do: send(worker, {:stdout, os_pid, "#{(batch - 1) * 100 + n}\n"})
          expected = batch * 100 + 1
          assert_receive {:live_received, ^expected}, 5_000
        end

        :ok
      end)

    send(exec, :finish)
    assert Task.await(reader) == count + 2
    refute_received :disk_replay
    assert :sys.get_state(worker).output_waiter == nil
    assert :sys.get_state(worker).buffer.bytes <= 65_536
    report(:live_handoff, Map.put(stats, :events, count))
    assert :ok = Jido.Harness.ProcessManager.prune_process(id)
  end

  defp load_size, do: System.get_env("HARNESS_LOAD_BYTES", "262144") |> String.to_integer() |> max(65_536)

  defp measure(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    {us, result} = :timer.tc(fun)
    {:reductions, after_count} = Process.info(self(), :reductions)
    {%{elapsed_us: us, reductions: after_count - before}, result}
  end

  defp report(name, metrics), do: IO.puts("harness_load " <> Jason.encode!(Map.put(metrics, :scenario, name)))
end
