defmodule Jido.Harness.Process do
  @moduledoc """
  Supervised lifecycle API for structured local OS processes.

  Processes are started from an executable plus argv, never an interpolated
  shell command. Their output is retained as cursor-addressable events.

  Public processes survive caller and stream-consumer exits. Cancellation
  targets the complete process group and escalates through SIGINT, SIGTERM, and
  SIGKILL.

  See [Managed processes](managed_processes.html) and the
  [process reference](process_management.html).
  """

  alias Jido.Harness.ProcessManager

  @doc "Starts a caller-independent OS process from a structured specification."
  @spec start(map() | keyword() | Jido.Harness.ProcessSpec.t()) :: Jido.Harness.result(String.t())
  def start(spec), do: ProcessManager.start_process(spec)

  @doc "Returns a redacted managed-process snapshot."
  @spec info(String.t()) :: Jido.Harness.result(Jido.Harness.ProcessInfo.t())
  def info(process_id), do: ProcessManager.info_process(process_id)

  @doc "Lists managed processes, optionally filtering with `states: [...]`."
  @spec list(keyword()) :: [Jido.Harness.ProcessInfo.t()]
  def list(filters \\ []), do: ProcessManager.list_processes(filters)

  @doc "Returns a cursor-driven stream for managed-process events."
  @spec stream(String.t(), keyword()) :: Jido.Harness.result(term())
  def stream(process_id, options \\ []), do: ProcessManager.stream_process(process_id, options)

  @doc "Replays a bounded page of managed-process events after a cursor."
  @spec replay(String.t(), keyword()) :: Jido.Harness.result([Jido.Harness.ProcessEvent.t()])
  def replay(process_id, options \\ []), do: ProcessManager.replay_process(process_id, options)

  @doc "Waits for termination without cancelling the process when the wait times out."
  @spec await(String.t(), timeout()) :: Jido.Harness.result(Jido.Harness.ProcessInfo.t())
  def await(process_id, timeout \\ :infinity), do: ProcessManager.await_process(process_id, timeout)

  @doc "Writes binary data to the process's standard input."
  @spec send_input(String.t(), binary()) :: :ok | {:error, term()}
  def send_input(process_id, data), do: ProcessManager.send_input(process_id, data)

  @doc "Closes a process's standard input."
  @spec close_input(String.t()) :: :ok | {:error, term()}
  def close_input(process_id), do: ProcessManager.close_input(process_id)

  @doc "Gracefully cancels a process using configured signal escalation."
  @spec cancel(String.t()) :: :ok | {:error, term()}
  def cancel(process_id), do: ProcessManager.cancel_process(process_id)

  @doc "Immediately kills a process group."
  @spec kill(String.t()) :: :ok | {:error, term()}
  def kill(process_id), do: ProcessManager.kill_process(process_id)

  @doc "Removes a terminal process and its retained journal."
  @spec prune(String.t()) :: :ok | {:error, term()}
  def prune(process_id), do: ProcessManager.prune_process(process_id)

  @doc "Builds an explicitly unsafe shell-backed process specification."
  @spec unsafe_shell_spec(String.t(), keyword()) :: Jido.Harness.result(Jido.Harness.ProcessSpec.t())
  def unsafe_shell_spec(command, options \\ []), do: ProcessManager.unsafe_shell_spec(command, options)
end
