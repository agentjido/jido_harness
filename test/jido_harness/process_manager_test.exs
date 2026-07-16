defmodule Jido.Harness.ProcessManagerTest do
  use ExUnit.Case, async: false

  import Jido.Harness.TestHelpers

  setup do
    journal_dir = Path.join(System.tmp_dir!(), "jido-harness-process-test-#{System.unique_integer([:positive])}")
    original = Application.get_env(:jido_harness, :process_manager)
    Application.put_env(:jido_harness, :process_manager, %{journal_dir: journal_dir})

    on_exit(fn ->
      cleanup_processes()

      if original,
        do: Application.put_env(:jido_harness, :process_manager, original),
        else: Application.delete_env(:jido_harness, :process_manager)

      File.rm_rf!(journal_dir)
    end)

    :ok
  end

  test "executes structured argv and replays ordered stdout and stderr" do
    assert {:ok, id} =
             Jido.Harness.start_process(%{
               executable: "/bin/sh",
               argv: ["-c", "printf stdout-value; printf stderr-value >&2"],
               stdin: false,
               metadata: %{purpose: "test"}
             })

    assert {:ok, info} = Jido.Harness.await_process(id, 5_000)
    assert info.state == :exited
    assert info.exit_status == 0
    assert info.metadata == %{purpose: "test"}

    assert {:ok, events} = Jido.Harness.replay_process(id, limit: 20)
    assert Enum.map(events, & &1.sequence) == Enum.to_list(1..length(events))
    assert Enum.any?(events, &(&1.type == :stdout and &1.data == "stdout-value"))
    assert Enum.any?(events, &(&1.type == :stderr and &1.data == "stderr-value"))
    assert List.last(events).type == :exited

    assert {:ok, stat} = File.stat(info.journal_dir)
    assert Bitwise.band(stat.mode, 0o777) == 0o700

    assert Enum.all?(Path.wildcard(Path.join(info.journal_dir, "*.jsonl")), fn path ->
             {:ok, file_stat} = File.stat(path)
             Bitwise.band(file_stat.mode, 0o777) == 0o600
           end)
  end

  test "supports stdin, EOF, cursor replay, and pull streaming" do
    assert {:ok, id} = Jido.Harness.start_process(executable: "/bin/cat", stdin: true)
    assert :ok = Jido.Harness.send_input(id, "one\ntwo\n")
    assert :ok = Jido.Harness.close_input(id)
    assert {:ok, %{state: :exited}} = Jido.Harness.await_process(id, 5_000)

    assert {:ok, all_events} = Jido.Harness.replay_process(id, limit: 20)
    first = List.first(all_events)
    assert {:ok, later} = Jido.Harness.replay_process(id, cursor: first.sequence, limit: 20)
    assert Enum.all?(later, &(&1.sequence > first.sequence))

    assert {:ok, stream} = Jido.Harness.stream_process(id, poll_interval_ms: 1)
    streamed = Enum.to_list(stream)
    assert Enum.map(streamed, & &1.sequence) == Enum.map(all_events, & &1.sequence)

    assert {:error, %Jido.Harness.Error{category: :validation}} =
             Jido.Harness.replay_process(id, cursor: -1, limit: 100)

    assert {:error, %Jido.Harness.Error{category: :validation}} =
             Jido.Harness.replay_process(id, limit: 10_001)

    assert {:error, %Jido.Harness.Error{category: :validation}} = Jido.Harness.send_input(id, :not_binary)
  end

  test "survives the starting caller and enforces runtime and idle timeouts" do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          Jido.Harness.start_process(%{
            executable: "/bin/sh",
            argv: ["-c", "sleep 0.1; printf detached"],
            stdin: false
          })

        send(parent, {:started, result})
      end)

    assert_receive {:started, {:ok, detached_id}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    assert {:ok, %{state: :exited}} = Jido.Harness.await_process(detached_id, 5_000)

    assert {:ok, timeout_id} =
             Jido.Harness.start_process(%{
               executable: "/bin/sleep",
               argv: ["30"],
               stdin: false,
               runtime_timeout_ms: 50
             })

    assert {:ok, %{state: :timed_out}} = Jido.Harness.await_process(timeout_id, 5_000)

    assert {:ok, idle_id} =
             Jido.Harness.start_process(%{
               executable: "/bin/sleep",
               argv: ["30"],
               stdin: false,
               idle_timeout_ms: 50
             })

    assert {:ok, %{state: :timed_out}} = Jido.Harness.await_process(idle_id, 5_000)
  end

  test "rejects shell strings and unknown process options" do
    assert {:error, %Jido.Harness.Error{category: :validation}} =
             Jido.Harness.start_process(%{executable: "/bin/echo", command: "unsafe"})

    assert {:ok, spec} = Jido.Harness.ProcessManager.unsafe_shell_spec("printf explicit")
    assert spec.executable =~ "sh"
    assert spec.argv == ["-c", "printf explicit"]

    assert {:ok, failure_id} =
             Jido.Harness.start_process(%{executable: "/bin/sh", argv: ["-c", "exit 3"], stdin: false})

    assert {:ok, %{state: :failed, exit_status: 3, error: {:exit_status, 3}}} =
             Jido.Harness.await_process(failure_id, 5_000)

    assert {:error, %Jido.Harness.Error{category: :validation}} =
             Jido.Harness.start_process(%{executable: "/bin/echo", pty: ["not", "keyword"]})
  end

  test "runs concurrent processes and an opt-in PTY" do
    ids =
      Enum.map(1..8, fn number ->
        assert {:ok, id} =
                 Jido.Harness.start_process(%{
                   executable: "/bin/echo",
                   argv: [Integer.to_string(number)],
                   stdin: false
                 })

        id
      end)

    assert Enum.all?(ids, fn id -> match?({:ok, %{state: :exited}}, Jido.Harness.await_process(id, 5_000)) end)

    if File.exists?("/usr/bin/tty") do
      assert {:ok, pty_id} =
               Jido.Harness.start_process(%{executable: "/usr/bin/tty", pty: true, stdin: true})

      assert {:ok, %{state: :exited}} = Jido.Harness.await_process(pty_id, 5_000)
      assert {:ok, events} = Jido.Harness.replay_process(pty_id, limit: 20)
      assert Enum.any?(events, &(&1.type == :stdout and String.contains?(&1.data, "/dev/")))
    end
  end

  test "escalates cancellation and kills the whole process group" do
    config = Application.get_env(:jido_harness, :process_manager, %{})

    Application.put_env(
      :jido_harness,
      :process_manager,
      Map.merge(config, %{cancel_grace_ms: 25, term_grace_ms: 25})
    )

    assert {:ok, id} =
             Jido.Harness.start_process(%{
               executable: "/bin/sh",
               argv: ["-c", "trap '' INT TERM; /bin/sh -c 'trap \"\" INT TERM; sleep 30' & printf \"%s\\n\" $!; wait"],
               stdin: false
             })

    child_pid = await_stdout_integer(id)
    assert :ok = Jido.Harness.cancel_process(id)
    assert {:ok, %{state: :cancelled}} = Jido.Harness.await_process(id, 5_000)
    Process.sleep(25)
    assert {_output, status} = System.cmd("/bin/kill", ["-0", Integer.to_string(child_pid)], stderr_to_stdout: true)
    assert status != 0
  end

  test "an abrupt process-manager worker crash cannot orphan its process group" do
    assert {:ok, id} =
             Jido.Harness.start_process(%{
               executable: "/bin/sh",
               argv: ["-c", "/bin/sh -c 'sleep 30' & printf \"%s\\n\" $!; wait"],
               stdin: false
             })

    child_pid = await_stdout_integer(id)
    [{worker, _value}] = Registry.lookup(Jido.Harness.ProcessRegistry, id)
    monitor = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000

    assert eventually(fn -> Registry.lookup(Jido.Harness.ProcessRegistry, id) == [] end)
    assert eventually(fn -> not process_alive?(child_pid) end)
  end

  test "continues with bounded memory and telemetry when the journal cannot open" do
    base = Path.join(System.tmp_dir!(), "jido-harness-journal-block-#{System.unique_integer([:positive])}")
    File.write!(base, "file")
    config = Application.get_env(:jido_harness, :process_manager, %{})
    Application.put_env(:jido_harness, :process_manager, Map.put(config, :journal_dir, base))

    handler = "journal-failure-#{System.unique_integer([:positive])}"
    owner = self()

    :telemetry.attach(
      handler,
      [:jido, :harness, :journal, :error],
      fn name, measurements, metadata, _config ->
        send(owner, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      File.rm(base)
    end)

    assert {:ok, id} =
             Jido.Harness.start_process(%{executable: "/bin/echo", argv: ["memory-only"], stdin: false})

    assert_receive {:telemetry, [:jido, :harness, :journal, :error], %{count: 1}, _metadata}, 1_000
    assert {:ok, %{state: :exited, journal_dir: nil}} = Jido.Harness.await_process(id, 5_000)
    assert {:ok, events} = Jido.Harness.replay_process(id, limit: 20)
    assert Enum.any?(events, &(&1.type == :stdout and String.contains?(&1.data, "memory-only")))
  end

  test "runs the deterministic long-session fixture in a short PR-safe mode" do
    fixture = Path.expand("../../priv/fixtures/long_running_cli.exs", __DIR__)

    assert {:ok, id} =
             Jido.Harness.start_process(%{
               executable: System.find_executable("elixir"),
               argv: [fixture, "100", "20"],
               stdin: false,
               runtime_timeout_ms: 10_000,
               idle_timeout_ms: 3_000
             })

    assert {:ok, %{state: :exited, exit_status: 0}} = Jido.Harness.await_process(id, 5_000)
    assert {:ok, events} = Jido.Harness.replay_process(id, limit: 100)
    assert Enum.count(events, &(&1.type == :stdout)) >= 2
  end

  defp await_stdout_integer(id, attempts \\ 100)

  defp await_stdout_integer(_id, 0), do: flunk("managed process did not emit a child pid")

  defp await_stdout_integer(id, attempts) do
    case Jido.Harness.replay_process(id, limit: 20) do
      {:ok, events} ->
        case Enum.find(events, &(&1.type == :stdout)) do
          nil ->
            Process.sleep(10)
            await_stdout_integer(id, attempts - 1)

          event ->
            event.data |> String.trim() |> String.to_integer()
        end

      _ ->
        Process.sleep(10)
        await_stdout_integer(id, attempts - 1)
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

  defp process_alive?(pid) do
    {_output, status} = System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    status == 0
  end
end
