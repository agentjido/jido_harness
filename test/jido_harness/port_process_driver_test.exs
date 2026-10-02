defmodule Jido.Harness.PortProcessDriverTest do
  # The driver Windows uses, through the process manager. It runs on every
  # system, so the child here is the Erlang runtime: the one program certain
  # to be installed wherever this suite runs.
  use ExUnit.Case, async: false

  import Jido.Harness.TestHelpers

  alias Jido.Harness.ProcessDriver
  alias Jido.Harness.ProcessDriver.Port, as: PortDriver

  # Repeats each line it reads; "quit" ends it with exit code 3
  @echo ~S"""
  F = fun L() ->
    case io:get_line("") of
      eof -> halt(0);
      Line ->
        case string:trim(Line) of
          "quit" -> halt(3);
          Text -> io:put_chars(["echo:", Text, "\n"]), L()
        end
    end
  end, F().
  """

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
    {:ok, id} = start_echo()

    assert :ok = Jido.Harness.Process.send_input(id, "one\n")
    assert :ok = Jido.Harness.Process.send_input(id, "two\n")
    await_output(id, "echo:two")
    assert :ok = Jido.Harness.Process.send_input(id, "quit\n")

    assert {:ok, info} = Jido.Harness.Process.await(id, 15_000)
    assert info.state == :failed
    assert info.exit_status == 3
    assert output(id) =~ ~r/echo:one\r?\necho:two/
  end

  test "arguments, the working directory and the environment reach the process" do
    cwd = System.tmp_dir!()

    program = ~S"""
    {ok, Cwd} = file:get_cwd(),
    io:format("~s|~s|~p|~p~n", [Cwd, os:getenv("HARNESS_SET"), os:getenv("HARNESS_GONE"), init:get_plain_arguments()]),
    halt(0).
    """

    System.put_env("HARNESS_GONE", "still here")
    on_exit(fn -> System.delete_env("HARNESS_GONE") end)

    {:ok, id} =
      Jido.Harness.Process.start(%{
        executable: erl(),
        argv: ["-noshell", "-eval", program, "-extra", "an argument", "two"],
        cwd: cwd,
        env: %{"HARNESS_SET" => "a value", "HARNESS_GONE" => nil}
      })

    assert {:ok, %{state: :exited, exit_status: 0}} = Jido.Harness.Process.await(id, 15_000)
    assert [dir, "a value", "false", arguments] = id |> output() |> String.trim() |> String.split("|")
    assert Path.basename(dir) == Path.basename(Path.expand(cwd))
    assert arguments =~ ~s("an argument")
    assert arguments =~ ~s("two")
  end

  test "a running process is stopped when it is killed" do
    {:ok, id} = start_echo()
    assert :ok = Jido.Harness.Process.send_input(id, "ready\n")
    await_output(id, "echo:ready")

    assert :ok = Jido.Harness.Process.kill(id)
    assert {:ok, info} = Jido.Harness.Process.await(id, 15_000)
    assert info.state == :cancelled
  end

  test "what a port cannot do is refused, not attempted" do
    {:ok, spec} = Jido.Harness.ProcessSpec.new(%{executable: erl(), pty: true})
    assert {:error, %Jido.Harness.Error{}} = PortDriver.start(spec, self())
    assert {:error, :unsupported} = PortDriver.send_input(self(), :eof)
  end

  test "an executable that is not there is an error" do
    assert {:ok, id} = Jido.Harness.Process.start(%{executable: Path.join(System.tmp_dir!(), "no-such-program")})
    assert {:ok, %{state: :failed}} = Jido.Harness.Process.await(id, 5_000)
  end

  test "on Windows a process is ended with the processes it started" do
    assert {executable, ["/PID", "42", "/T", "/F"]} = PortDriver.kill_command({:win32, :nt}, 42, :sigint)
    assert executable =~ "taskkill"
    assert {_kill, ["-s", "TERM", "42"]} = PortDriver.kill_command({:unix, :linux}, 42, :sigterm)
  end

  defp start_echo do
    Jido.Harness.Process.start(%{executable: erl(), argv: ["-noshell", "-eval", @echo]})
  end

  defp erl, do: System.find_executable("erl")

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
