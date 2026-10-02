defmodule Jido.Harness.PortProcessDriverTest do
  # The driver Windows uses, through the process manager. It runs on every
  # system, so the child here is the system's own command interpreter, given
  # the few commands both of them understand.
  use ExUnit.Case, async: false

  import Jido.Harness.TestHelpers

  alias Jido.Harness.ProcessDriver
  alias Jido.Harness.ProcessDriver.Port, as: PortDriver

  setup do
    journal_dir = Path.join(System.tmp_dir!(), "jido-harness-port-test-#{System.unique_integer([:positive])}")
    manager = Application.get_env(:jido_harness, :process_manager)
    driver = Application.get_env(:jido_harness, :process_driver)
    Application.put_env(:jido_harness, :process_manager, %{journal_dir: journal_dir})
    Application.put_env(:jido_harness, :process_driver, PortDriver)

    on_exit(fn ->
      cleanup_processes()
      restore(:process_manager, manager)
      restore(:process_driver, driver)
      File.rm_rf!(journal_dir)
    end)

    :ok
  end

  test "Windows gets this driver and every other system erlexec" do
    assert ProcessDriver.default({:win32, :nt}) == PortDriver
    assert ProcessDriver.default({:unix, :linux}) == ProcessDriver.Erlexec
    assert ProcessDriver.default({:unix, :darwin}) == ProcessDriver.Erlexec
  end

  test "a process is given input, its output is read and its exit code reported" do
    {:ok, id} = start_interpreter()

    assert :ok = Jido.Harness.Process.send_input(id, "echo echo:one\n")
    assert :ok = Jido.Harness.Process.send_input(id, "echo echo:two\n")
    await_output(id, "echo:two")
    assert :ok = Jido.Harness.Process.send_input(id, "exit 3\n")

    assert {:ok, info} = Jido.Harness.Process.await(id, 15_000)
    assert info.state == :failed
    assert info.exit_status == 3
    assert output(id) =~ ~r/echo:one.*echo:two/s
  end

  test "the working directory and the environment reach the process" do
    cwd = Path.join(System.tmp_dir!(), "harness port #{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    System.put_env("HARNESS_GONE", "still here")

    on_exit(fn ->
      System.delete_env("HARNESS_GONE")
      File.rm_rf(cwd)
    end)

    {:ok, id} = start_interpreter(cwd: cwd, env: %{"HARNESS_SET" => "a value", "HARNESS_GONE" => nil})

    {where, variables} =
      if windows?(),
        do: {"cd\n", "echo [%HARNESS_SET%] [%HARNESS_GONE%]\n"},
        else: {"pwd\n", "echo [$HARNESS_SET] [$HARNESS_GONE]\n"}

    assert :ok = Jido.Harness.Process.send_input(id, where <> variables <> "exit 0\n")
    assert {:ok, %{state: :exited, exit_status: 0}} = Jido.Harness.Process.await(id, 15_000)

    assert output(id) =~ Path.basename(cwd)
    assert output(id) =~ "[a value]"
    refute output(id) =~ "still here"
  end

  test "arguments reach the process as they are, spaces included" do
    argv =
      if windows?(),
        do: ["/d", "/c", "echo", "an argument", "two"],
        else: ["-c", ~S(printf '"%s" %s' "$1" "$2"), "sh", "an argument", "two"]

    {:ok, id} = Jido.Harness.Process.start(%{executable: interpreter(), argv: argv})

    assert {:ok, %{state: :exited}} = Jido.Harness.Process.await(id, 15_000)
    assert output(id) =~ ~s("an argument" two)
  end

  test "a running process is stopped when it is killed" do
    {:ok, id} = start_interpreter()
    assert :ok = Jido.Harness.Process.send_input(id, "echo echo:ready\n")
    await_output(id, "echo:ready")

    assert :ok = Jido.Harness.Process.kill(id)
    assert {:ok, info} = Jido.Harness.Process.await(id, 15_000)
    assert info.state == :cancelled
  end

  test "what a port cannot do is refused, not attempted" do
    {:ok, spec} = Jido.Harness.ProcessSpec.new(%{executable: interpreter(), pty: true})
    assert {:error, %Jido.Harness.Error{}} = PortDriver.start(spec, self())
    assert {:error, :unsupported} = PortDriver.send_input(self(), :eof)
  end

  test "an executable that is not there is an error" do
    assert {:ok, id} = Jido.Harness.Process.start(%{executable: Path.join(System.tmp_dir!(), "no-such-program")})
    assert {:ok, %{state: :failed}} = Jido.Harness.Process.await(id, 5_000)
  end

  test "on Windows a batch file is given to the command interpreter, quoted" do
    assert {:ok, {:spawn, line}} =
             PortDriver.command({:win32, :nt}, "C:/Program Files/npm/agent.CMD", ["--flag", "a b"])

    assert to_string(line) =~ ~S(/d /s /c ""C:\Program Files\npm\agent.CMD" "--flag" "a b"")

    assert {:ok, {:spawn_executable, ~c"C:/bin/agent.exe"}} =
             PortDriver.command({:win32, :nt}, "C:/bin/agent.exe", ["x"])

    assert {:ok, {:spawn_executable, ~c"/bin/agent.cmd"}} =
             PortDriver.command({:unix, :linux}, "/bin/agent.cmd", [])

    for argument <- [~s(say "hi"), "100%", "two\nlines"] do
      assert {:error, _reason} = PortDriver.command({:win32, :nt}, "C:/agent.cmd", [argument])
    end
  end

  test "on Windows a process is ended with the processes it started" do
    assert {executable, ["/PID", "42", "/T", "/F"]} = PortDriver.kill_command({:win32, :nt}, 42, :sigint)
    assert executable =~ "taskkill"
    assert {_kill, ["-s", "TERM", "42"]} = PortDriver.kill_command({:unix, :linux}, 42, :sigterm)
  end

  defp start_interpreter(options \\ []) do
    argv = if windows?(), do: ["/d", "/q"], else: []
    Jido.Harness.Process.start(Map.merge(%{executable: interpreter(), argv: argv}, Map.new(options)))
  end

  defp interpreter, do: if(windows?(), do: System.get_env("ComSpec") || "cmd.exe", else: "sh")
  defp windows?, do: match?({:win32, _name}, :os.type())

  defp output(id) do
    {:ok, events} = Jido.Harness.Process.replay(id)
    events |> Enum.filter(&(&1.type == :stdout)) |> Enum.map_join(& &1.data)
  end

  defp await_output(id, text, attempts \\ 200)
  defp await_output(id, text, 0), do: flunk("no #{inspect(text)} in #{inspect(output(id))}")

  defp await_output(id, text, attempts) do
    if output(id) =~ text do
      :ok
    else
      Process.sleep(50)
      await_output(id, text, attempts - 1)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:jido_harness, key)
  defp restore(key, value), do: Application.put_env(:jido_harness, key, value)
end
