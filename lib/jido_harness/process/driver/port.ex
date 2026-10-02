defmodule Jido.Harness.ProcessDriver.Port do
  @moduledoc false
  # Runs a process through an Erlang port instead of erlexec, whose native
  # helper is not built for Windows. It is the default driver there and works
  # on the other systems too, which is how it is tested.
  #
  # What a port cannot do, and erlexec can:
  #
  #   * a pseudo-terminal: a specification asking for one is refused
  #   * standard error as its own stream: it is not captured (merging it into
  #     standard output would break protocols that own that stream, as ACP does)
  #   * closing standard input alone: `:eof` is refused, and a specification
  #     with `stdin: false` starts with standard input open
  #   * signals on Windows: every signal ends the process and its children
  @behaviour Jido.Harness.ProcessDriver

  alias Jido.Harness.ProcessSpec

  # Stands for the process id of a process that ended before it could be asked
  # for: no process has it, and nothing is signalled with it.
  @ended 0

  @impl true
  def start(%ProcessSpec{pty: pty}, _owner) when pty != false do
    {:error, Jido.Harness.Error.validation("this system's process driver has no pseudo-terminal")}
  end

  def start(%ProcessSpec{} = spec, owner) do
    with :ok <- validate_cwd(spec.cwd),
         {:ok, executable} <- ProcessSpec.resolve_executable(spec.executable) do
      caller = self()
      ref = make_ref()
      pid = spawn_link(fn -> run(executable, spec, owner, caller, ref) end)

      receive do
        {^ref, {:ok, os_pid}} -> {:ok, pid, os_pid}
        {^ref, {:error, reason}} -> {:error, reason}
      after
        spec.startup_timeout_ms ->
          Process.unlink(pid)
          Process.exit(pid, :kill)
          {:error, :timeout}
      end
    end
  end

  @impl true
  def send_input(_process, :eof), do: {:error, :unsupported}

  def send_input(process, data) when is_pid(process) do
    send(process, {:input, data})
    :ok
  end

  def send_input(_process, _data), do: {:error, :not_running}

  @impl true
  def signal(@ended, _signal), do: :ok

  def signal(os_pid, signal) when is_integer(os_pid) do
    {executable, arguments} = kill_command(:os.type(), os_pid, signal)

    case System.cmd(executable, arguments, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:signal_failed, signal, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:signal_failed, signal, error}}
  end

  def signal(_process, signal), do: {:error, {:signal_failed, signal, :no_os_pid}}

  @doc false
  # Windows has no signals a console program can be sent from outside: the
  # only way to stop one, with the processes it started, is to end them.
  def kill_command({:win32, _name}, os_pid, _signal) do
    root = System.get_env("SystemRoot") || "C:\\Windows"
    executable = System.find_executable("taskkill") || Path.join([root, "System32", "taskkill.exe"])
    {executable, ["/PID", Integer.to_string(os_pid), "/T", "/F"]}
  end

  def kill_command(_os, os_pid, signal) do
    executable = System.find_executable("kill") || "/bin/kill"
    {executable, ["-s", signal_name(signal), Integer.to_string(os_pid)]}
  end

  @doc false
  # Windows starts programs, not batch files: a .cmd or .bat file (what npm
  # installs a command as) has to be given to the command interpreter. Its
  # command line is written here, quoted, and not left to the port, whose
  # quoting the interpreter does not read. `%` and `"` keep their meaning to
  # the interpreter inside quotes, so an argument with one is refused rather
  # than passed on as something else.
  def command({:win32, _name}, executable, argv) do
    if String.downcase(Path.extname(executable)) in [".cmd", ".bat"] do
      batch_command(executable, argv)
    else
      {:ok, {:spawn_executable, String.to_charlist(executable)}}
    end
  end

  def command(_os, executable, _argv), do: {:ok, {:spawn_executable, String.to_charlist(executable)}}

  defp batch_command(executable, argv) do
    words = [String.replace(executable, "/", "\\") | argv]

    if Enum.any?(words, &String.contains?(&1, ["\"", "%", "\r", "\n"])) do
      {:error, "a batch file cannot be given an argument with a quote, a percent sign or a line break"}
    else
      interpreter = System.get_env("ComSpec") || "cmd.exe"
      quoted = Enum.map_join(words, " ", &("\"" <> &1 <> "\""))
      {:ok, {:spawn, String.to_charlist("#{interpreter} /d /s /c \"#{quoted}\"")}}
    end
  end

  defp signal_name(:sigint), do: "INT"
  defp signal_name(:sigterm), do: "TERM"
  defp signal_name(:sigkill), do: "KILL"
  defp signal_name(signal) when is_integer(signal), do: Integer.to_string(signal)

  defp validate_cwd(cwd) do
    if File.dir?(cwd) do
      :ok
    else
      {:error, Jido.Harness.Error.validation("cwd must be an existing directory", details: %{cwd: cwd})}
    end
  end

  defp run(executable, spec, owner, caller, ref) do
    options = [
      :binary,
      :exit_status,
      :use_stdio,
      :hide,
      args: spec.argv,
      cd: String.to_charlist(spec.cwd),
      env: environment(spec.env_mode, spec.env)
    ]

    port =
      case command(:os.type(), executable, spec.argv) do
        {:ok, {:spawn_executable, _path} = name} -> Port.open(name, options)
        {:ok, {:spawn, _line} = name} -> Port.open(name, List.keydelete(options, :args, 0))
        {:error, reason} -> raise ArgumentError, reason
      end

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        send(caller, {ref, {:ok, os_pid}})
        loop(port, os_pid, owner)

      # Already over: a port forgets the process id once the process has
      # ended. Its output and exit code are still to be read from the port.
      nil ->
        send(caller, {ref, {:ok, @ended}})
        loop(port, @ended, owner)
    end
  rescue
    error -> send(caller, {ref, {:error, error}})
  end

  defp loop(port, os_pid, owner) do
    receive do
      {^port, {:data, data}} ->
        send(owner, {:stdout, os_pid, data})
        loop(port, os_pid, owner)

      # Not the status erlexec reports, which is the one wait(2) gives and
      # has to be decoded: this is the exit code itself.
      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, code}} ->
        exit({:exit_code, code})

      {:input, data} ->
        Port.command(port, data)
        loop(port, os_pid, owner)

      _other ->
        loop(port, os_pid, owner)
    end
  end

  # A port adds to the environment of this system process and takes away the
  # names given as `false`; replacing it is taking away every other name.
  defp environment(mode, env) do
    cleared =
      if mode == :replace do
        for {name, _value} <- System.get_env(), not is_map_key(env, name), do: {name, false}
      else
        []
      end

    Enum.map(cleared ++ Map.to_list(env), fn
      {name, value} when value in [nil, false] -> {String.to_charlist(name), false}
      {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
    end)
  end
end
