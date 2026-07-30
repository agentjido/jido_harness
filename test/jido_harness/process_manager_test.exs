defmodule Jido.Harness.ProcessManagerTest do
  use ExUnit.Case, async: false

  import Jido.Harness.TestHelpers

  defmodule ControlledExitDriver do
    @behaviour Jido.Harness.ProcessDriver

    @impl true
    def start(_spec, owner) do
      test_pid = Application.fetch_env!(:jido_harness, :process_manager_test_pid)
      os_pid = System.unique_integer([:positive])

      exec_pid =
        spawn_link(fn ->
          send(test_pid, {:driver_ready, self(), owner, os_pid})

          receive do
            {:exit, reason, caller} ->
              send(caller, {:driver_exiting, self(), reason})
              exit(reason)
          end
        end)

      {:ok, exec_pid, os_pid}
    end

    @impl true
    def send_input(_process, _data), do: :ok

    @impl true
    def signal(process, signal) do
      if test_pid = Application.get_env(:jido_harness, :process_manager_test_pid),
        do: send(test_pid, {:driver_signal, process, signal})

      :ok
    end
  end

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
             Jido.Harness.Process.start(%{
               executable: "/bin/sh",
               argv: ["-c", "printf stdout-value; printf stderr-value >&2"],
               stdin: false,
               metadata: %{purpose: "test"}
             })

    assert {:ok, info} = Jido.Harness.Process.await(id, 5_000)
    assert info.state == :exited
    assert info.exit_status == 0
    assert info.metadata == %{purpose: "test"}

    assert {:ok, events} = Jido.Harness.Process.replay(id, limit: 20)
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

  test "drains output that arrives immediately after the execution exit signal" do
    {id, worker, exec_pid, os_pid} = start_controlled_process(%{output_drain_ms: 100})
    state = begin_exit_drain(worker, exec_pid)
    send(worker, {:stdout, os_pid, "late-output"})
    state = await_worker_state(worker, &(&1.sequence > state.sequence))
    send(worker, {:finish_exit, state.exit_drain_token})

    assert {:ok, %{state: :exited}} = Jido.Harness.Process.await(id, 5_000)
    assert {:ok, events} = Jido.Harness.Process.replay(id, limit: 20)

    assert Enum.any?(events, &(&1.type == :stdout and &1.data == "late-output"))
    assert List.last(events).type == :exited
  end

  test "continuous output cannot extend the exit drain without limit" do
    {id, worker, exec_pid, os_pid} = start_controlled_process(%{output_drain_ms: 10})
    _state = begin_exit_drain(worker, exec_pid)
    producer = spawn(fn -> output_loop(worker, os_pid) end)
    send(producer, :emit)

    assert {:ok, %{state: :exited}} = Jido.Harness.Process.await(id, 1_000)
    send(producer, :stop)

    assert {:ok, events} = Jido.Harness.Process.replay(id, limit: 100)
    assert Enum.any?(events, &(&1.type == :stdout and &1.data == "trailing-output"))
    assert List.last(events).type == :exited
  end

  test "an observed exit is not replaced by drain-window control messages" do
    lifecycle_owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    owner_monitor = Process.monitor(lifecycle_owner)

    {id, worker, exec_pid, _os_pid} =
      start_controlled_process(
        %{output_drain_ms: 500, runtime_timeout_ms: 5_000, idle_timeout_ms: 5_000},
        lifecycle_owner
      )

    running = :sys.get_state(worker)
    _state = begin_exit_drain(worker, exec_pid)

    assert {:error, :not_running} = Jido.Harness.Process.send_input(id, "ignored")
    assert :ok = Jido.Harness.Process.cancel(id)
    assert :ok = Jido.Harness.Process.kill(id)

    send(worker, {:runtime_timeout, running.runtime_token})
    send(worker, {:idle_timeout, running.idle_token})
    send(worker, {:escalate, :sigterm})
    send(worker, {:escalate, :sigkill})
    send(worker, {:EXIT, exec_pid, :duplicate_exit})

    Process.exit(lifecycle_owner, :shutdown)
    assert_receive {:DOWN, ^owner_monitor, :process, ^lifecycle_owner, :shutdown}, 1_000
    send(worker, {:DOWN, running.owner_monitor, :process, lifecycle_owner, :shutdown})

    state = :sys.get_state(worker)
    assert state.exit_reason == :normal
    assert state.stop_reason == nil
    assert state.runtime_token == nil
    assert state.idle_token == nil
    refute_received {:driver_signal, _process, _signal}

    send(worker, {:finish_exit_deadline, state.exit_drain_deadline_token})
    assert {:ok, %{state: :exited, exit_status: 0}} = Jido.Harness.Process.await(id, 1_000)

    send(worker, {:EXIT, exec_pid, :duplicate_after_terminal})
    terminal = :sys.get_state(worker)
    assert terminal.status == :exited
    assert terminal.exit_drain_token == nil
    assert terminal.exit_drain_deadline_token == nil
  end

  test "zero output drain finalizes an observed exit immediately" do
    {id, _worker, exec_pid, _os_pid} = start_controlled_process(%{output_drain_ms: 0})
    exec_monitor = Process.monitor(exec_pid)
    send(exec_pid, {:exit, :normal, self()})
    assert_receive {:driver_exiting, ^exec_pid, :normal}, 1_000
    assert_receive {:DOWN, ^exec_monitor, :process, ^exec_pid, :normal}, 1_000

    assert {:ok, %{state: :exited, exit_status: 0}} = Jido.Harness.Process.await(id, 1_000)
    assert {:ok, events} = Jido.Harness.Process.replay(id, limit: 20)
    assert List.last(events).type == :exited
  end

  test "supports stdin, EOF, cursor replay, and pull streaming" do
    assert {:ok, id} = Jido.Harness.Process.start(executable: "/bin/cat", stdin: true)
    assert :ok = Jido.Harness.Process.send_input(id, "one\ntwo\n")
    assert :ok = Jido.Harness.Process.close_input(id)
    assert {:ok, %{state: :exited}} = Jido.Harness.Process.await(id, 5_000)

    assert {:ok, all_events} = Jido.Harness.Process.replay(id, limit: 20)
    first = List.first(all_events)
    assert {:ok, later} = Jido.Harness.Process.replay(id, cursor: first.sequence, limit: 20)
    assert Enum.all?(later, &(&1.sequence > first.sequence))

    assert {:ok, stream} = Jido.Harness.Process.stream(id, poll_interval_ms: 1)
    streamed = Enum.to_list(stream)
    assert Enum.map(streamed, & &1.sequence) == Enum.map(all_events, & &1.sequence)

    assert {:error, %Jido.Harness.Error{category: :validation}} =
             Jido.Harness.Process.replay(id, cursor: -1, limit: 100)

    assert {:error, %Jido.Harness.Error{category: :validation}} =
             Jido.Harness.Process.replay(id, limit: 10_001)

    assert {:error, %Jido.Harness.Error{category: :validation}} = Jido.Harness.Process.send_input(id, :not_binary)
  end

  test "await timeout is non-destructive and releases its waiter" do
    assert {:ok, id} =
             Jido.Harness.Process.start(%{
               executable: "/bin/sh",
               argv: ["-c", "sleep 0.1"],
               stdin: false
             })

    assert {:error, :timeout} = Jido.Harness.Process.await(id, 10)
    assert {:ok, %{state: state}} = Jido.Harness.Process.info(id)
    assert state in [:starting, :running]

    [{worker, _value}] = Registry.lookup(Jido.Harness.ProcessRegistry, id)
    assert eventually(fn -> :sys.get_state(worker).waiters == %{} end)

    assert {:ok, %{state: :exited}} = Jido.Harness.Process.await(id, 5_000)
  end

  test "survives the starting caller and enforces runtime and idle timeouts" do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          Jido.Harness.Process.start(%{
            executable: "/bin/sh",
            argv: ["-c", "sleep 0.1; printf detached"],
            stdin: false
          })

        send(parent, {:started, result})
      end)

    assert_receive {:started, {:ok, detached_id}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    assert {:ok, %{state: :exited}} = Jido.Harness.Process.await(detached_id, 5_000)

    assert {:ok, timeout_id} =
             Jido.Harness.Process.start(%{
               executable: "/bin/sleep",
               argv: ["30"],
               stdin: false,
               runtime_timeout_ms: 50
             })

    assert {:ok, %{state: :timed_out}} = Jido.Harness.Process.await(timeout_id, 5_000)

    assert {:ok, idle_id} =
             Jido.Harness.Process.start(%{
               executable: "/bin/sleep",
               argv: ["30"],
               stdin: false,
               idle_timeout_ms: 50
             })

    assert {:ok, %{state: :timed_out}} = Jido.Harness.Process.await(idle_id, 5_000)
  end

  test "rejects shell strings and unknown process options" do
    assert {:error, %Jido.Harness.Error{category: :validation}} =
             Jido.Harness.Process.start(%{executable: "/bin/echo", command: "unsafe"})

    assert {:ok, spec} = Jido.Harness.ProcessManager.unsafe_shell_spec("printf explicit")
    assert spec.executable =~ "sh"
    assert spec.argv == ["-c", "printf explicit"]

    assert {:ok, failure_id} =
             Jido.Harness.Process.start(%{executable: "/bin/sh", argv: ["-c", "exit 3"], stdin: false})

    assert {:ok, %{state: :failed, exit_status: 3, error: {:exit_status, 3}}} =
             Jido.Harness.Process.await(failure_id, 5_000)

    assert {:error, %Jido.Harness.Error{category: :validation}} =
             Jido.Harness.Process.start(%{executable: "/bin/echo", pty: ["not", "keyword"]})

    assert {:error, %Jido.Harness.Error{message: "process specification must be a map"}} =
             Jido.Harness.Process.start([:invalid])

    assert {:error, %Jido.Harness.Error{message: "await timeout must be :infinity or a non-negative integer"}} =
             Jido.Harness.Process.await("missing", -1)

    assert {:error, %Jido.Harness.Error{message: "options must be a keyword list"}} =
             Jido.Harness.Process.replay("missing", %{cursor: 0})
  end

  test "runs concurrent processes and an opt-in PTY" do
    ids =
      Enum.map(1..8, fn number ->
        assert {:ok, id} =
                 Jido.Harness.Process.start(%{
                   executable: "/bin/echo",
                   argv: [Integer.to_string(number)],
                   stdin: false
                 })

        id
      end)

    assert Enum.all?(ids, fn id -> match?({:ok, %{state: :exited}}, Jido.Harness.Process.await(id, 5_000)) end)

    if File.exists?("/usr/bin/tty") do
      assert {:ok, pty_id} =
               Jido.Harness.Process.start(%{executable: "/usr/bin/tty", pty: true, stdin: true})

      assert {:ok, %{state: :exited}} = Jido.Harness.Process.await(pty_id, 5_000)
      assert {:ok, events} = Jido.Harness.Process.replay(pty_id, limit: 20)
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
             Jido.Harness.Process.start(%{
               executable: "/bin/sh",
               argv: ["-c", "trap '' INT TERM; /bin/sh -c 'trap \"\" INT TERM; sleep 30' & printf \"%s\\n\" $!; wait"],
               stdin: false
             })

    child_pid = await_stdout_integer(id)
    assert :ok = Jido.Harness.Process.cancel(id)
    assert {:ok, %{state: :cancelled}} = Jido.Harness.Process.await(id, 5_000)
    Process.sleep(25)
    assert {_output, status} = System.cmd("/bin/kill", ["-0", Integer.to_string(child_pid)], stderr_to_stdout: true)
    assert status != 0
  end

  test "an abrupt process-manager worker crash cannot orphan its process group" do
    assert {:ok, id} =
             Jido.Harness.Process.start(%{
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
             Jido.Harness.Process.start(%{executable: "/bin/echo", argv: ["memory-only"], stdin: false})

    assert_receive {:telemetry, [:jido, :harness, :journal, :error], %{count: 1}, _metadata}, 1_000
    assert {:ok, %{state: :exited, journal_dir: nil}} = Jido.Harness.Process.await(id, 5_000)
    assert {:ok, events} = Jido.Harness.Process.replay(id, limit: 20)
    assert Enum.any?(events, &(&1.type == :stdout and String.contains?(&1.data, "memory-only")))
  end

  test "redacts request environment credentials from persisted process output" do
    secret = "fixture-secret-#{System.unique_integer([:positive])}"

    assert {:ok, id} =
             Jido.Harness.Process.start(%{
               executable: "/bin/sh",
               argv: ["-c", "printf %s \"$HARNESS_API_TOKEN\""],
               env: %{"HARNESS_API_TOKEN" => secret},
               stdin: false
             })

    assert {:ok, %{state: :exited, journal_dir: journal_dir}} = Jido.Harness.Process.await(id, 5_000)
    assert {:ok, events} = Jido.Harness.Process.replay(id, limit: 20)
    assert Enum.any?(events, &(&1.type == :stdout and &1.data == "[REDACTED]"))

    persisted = journal_dir |> Path.join("*.jsonl") |> Path.wildcard() |> Enum.map_join(&File.read!/1)
    refute persisted =~ secret
  end

  test "replacement environment excludes ambient host variables" do
    sentinel_name = "JIDO_HARNESS_HOST_SENTINEL"
    previous = System.get_env(sentinel_name)
    System.put_env(sentinel_name, "must-not-leak")

    on_exit(fn ->
      if previous,
        do: System.put_env(sentinel_name, previous),
        else: System.delete_env(sentinel_name)
    end)

    assert {:ok, id} =
             Jido.Harness.Process.start(%{
               executable: "/bin/sh",
               argv: ["-c", "printf '%s|%s' \"${JIDO_HARNESS_HOST_SENTINEL-unset}\" \"$RUN_SCOPE\""],
               env: %{"RUN_SCOPE" => "scoped"},
               env_mode: :replace,
               stdin: false
             })

    assert {:ok, %{state: :exited}} = Jido.Harness.Process.await(id, 5_000)
    assert {:ok, events} = Jido.Harness.Process.replay(id, limit: 20)
    assert Enum.any?(events, &(&1.type == :stdout and &1.data == "unset|scoped"))
  end

  test "runs the deterministic long-session fixture in a short PR-safe mode" do
    fixture = Jido.Harness.TestHelpers.fixture_path("long_running_cli.exs")

    assert {:ok, id} =
             Jido.Harness.Process.start(%{
               executable: System.find_executable("elixir"),
               argv: [fixture, "100", "20"],
               stdin: false,
               runtime_timeout_ms: 10_000,
               idle_timeout_ms: 3_000
             })

    assert {:ok, %{state: :exited, exit_status: 0}} = Jido.Harness.Process.await(id, 5_000)
    assert {:ok, events} = Jido.Harness.Process.replay(id, limit: 100)
    assert Enum.count(events, &(&1.type == :stdout)) >= 2
  end

  defp await_stdout_integer(id, attempts \\ 100)

  defp await_stdout_integer(_id, 0), do: flunk("managed process did not emit a child pid")

  defp await_stdout_integer(id, attempts) do
    case Jido.Harness.Process.replay(id, limit: 20) do
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

  defp start_controlled_process(manager_options, lifecycle_owner \\ nil) do
    original_driver = Application.get_env(:jido_harness, :process_driver)
    original_test_pid = Application.get_env(:jido_harness, :process_manager_test_pid)
    manager_config = Application.get_env(:jido_harness, :process_manager, %{})
    spec_options = Map.take(manager_options, [:runtime_timeout_ms, :idle_timeout_ms])
    manager_options = Map.drop(manager_options, [:runtime_timeout_ms, :idle_timeout_ms])

    Application.put_env(:jido_harness, :process_driver, ControlledExitDriver)
    Application.put_env(:jido_harness, :process_manager_test_pid, self())
    Application.put_env(:jido_harness, :process_manager, Map.merge(manager_config, manager_options))

    on_exit(fn ->
      if original_driver,
        do: Application.put_env(:jido_harness, :process_driver, original_driver),
        else: Application.delete_env(:jido_harness, :process_driver)

      if original_test_pid,
        do: Application.put_env(:jido_harness, :process_manager_test_pid, original_test_pid),
        else: Application.delete_env(:jido_harness, :process_manager_test_pid)
    end)

    spec = Map.merge(%{executable: "/bin/true", stdin: true}, spec_options)

    result =
      if lifecycle_owner,
        do: Jido.Harness.ProcessManager.start_owned_process(spec, lifecycle_owner),
        else: Jido.Harness.Process.start(spec)

    assert {:ok, id} = result
    assert_receive {:driver_ready, exec_pid, worker, os_pid}, 1_000
    assert [{^worker, _value}] = Registry.lookup(Jido.Harness.ProcessRegistry, id)
    {id, worker, exec_pid, os_pid}
  end

  defp begin_exit_drain(worker, exec_pid) do
    exec_monitor = Process.monitor(exec_pid)
    send(exec_pid, {:exit, :normal, self()})
    assert_receive {:driver_exiting, ^exec_pid, :normal}, 1_000
    assert_receive {:DOWN, ^exec_monitor, :process, ^exec_pid, :normal}, 1_000
    await_worker_state(worker, &(not is_nil(&1.exit_drain_token)))
  end

  defp await_worker_state(worker, predicate, attempts \\ 1_000)

  defp await_worker_state(_worker, _predicate, 0), do: flunk("process worker did not reach the expected state")

  defp await_worker_state(worker, predicate, attempts) do
    state = :sys.get_state(worker)
    if predicate.(state), do: state, else: await_worker_state(worker, predicate, attempts - 1)
  end

  defp output_loop(worker, os_pid) do
    receive do
      :emit ->
        send(worker, {:stdout, os_pid, "trailing-output"})
        Process.send_after(self(), :emit, 1)
        output_loop(worker, os_pid)

      :stop ->
        :ok
    end
  end

  defp process_alive?(pid) do
    {_output, status} = System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    status == 0
  end
end
