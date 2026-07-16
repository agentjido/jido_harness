defmodule Jido.Harness.ProcessDriver.Erlexec do
  @moduledoc false
  @behaviour Jido.Harness.ProcessDriver

  alias Jido.Harness.ProcessSpec

  @impl true
  def start(%ProcessSpec{} = spec, owner) do
    with {:ok, executable} <- ProcessSpec.resolve_executable(spec.executable) do
      command = [executable | spec.argv]

      options =
        [:link, {:group, 0}, :kill_group, {:cd, spec.cwd}]
        |> add_output(owner, spec.pty)
        |> maybe_stdin(spec.stdin, spec.pty)
        |> add_env(spec.env_mode, spec.env)

      case :exec.run(command, options, spec.startup_timeout_ms) do
        {:ok, _exec_pid, os_pid} = result ->
          if spec.pty != false and not spec.stdin, do: :exec.send(os_pid, <<4>>)
          result

        error ->
          error
      end
    end
  end

  @impl true
  def send_input(process, data), do: :exec.send(process, data)

  @impl true
  def signal(os_pid, signal) when is_integer(os_pid) do
    case :os.type() do
      {:unix, _name} -> signal_process_group(os_pid, signal)
      _other -> :exec.kill(os_pid, signal)
    end
  end

  def signal(process, signal), do: :exec.kill(process, signal)

  defp maybe_stdin(options, true, _pty), do: [:stdin | options]
  defp maybe_stdin(options, false, false), do: [{:stdin, :close} | options]
  defp maybe_stdin(options, false, _pty), do: [:stdin | options]

  defp add_output(options, owner, false), do: [{:stdout, owner}, {:stderr, owner} | options]
  defp add_output(options, owner, true), do: [{:stdout, owner}, {:stderr, :stdout}, :pty | options]

  defp add_output(options, owner, settings) when is_list(settings),
    do: [{:stdout, owner}, {:stderr, :stdout}, {:pty, settings} | options]

  defp add_env(options, mode, env) do
    entries =
      Enum.map(env, fn
        {key, nil} -> {key, false}
        {key, value} -> {key, value}
      end)

    entries = if mode == :replace, do: [:clear | entries], else: entries
    [{:env, entries} | options]
  end

  defp signal_process_group(os_pid, signal) do
    executable = System.find_executable("kill") || "/bin/kill"

    case System.cmd(executable, ["-s", signal_name(signal), "-#{os_pid}"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:signal_failed, signal, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:signal_failed, signal, error}}
  end

  defp signal_name(:sigint), do: "INT"
  defp signal_name(:sigterm), do: "TERM"
  defp signal_name(:sigkill), do: "KILL"
  defp signal_name(signal) when is_integer(signal), do: Integer.to_string(signal)
end
