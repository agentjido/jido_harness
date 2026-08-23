defmodule Jido.Harness.StructuredOutput.WorkspaceGuard do
  @moduledoc false

  alias Jido.Harness.StructuredOutput.SchemaWorkspace

  @doc false
  @spec start(SchemaWorkspace.t(), pid()) :: {:ok, pid()} | {:error, :guard_start_timeout}
  def start(%SchemaWorkspace{} = workspace, owner) when is_pid(owner) do
    caller = self()
    reference = make_ref()

    pid =
      spawn(fn ->
        monitor = Process.monitor(owner)
        send(caller, {:workspace_guard_started, reference, self()})
        loop(workspace, monitor)
      end)

    receive do
      {:workspace_guard_started, ^reference, ^pid} -> {:ok, pid}
    after
      5_000 ->
        Process.exit(pid, :kill)
        {:error, :guard_start_timeout}
    end
  end

  @doc false
  @spec close(pid()) :: :ok
  def close(pid) when is_pid(pid) do
    reference = make_ref()
    monitor = Process.monitor(pid)
    send(pid, {:close, self(), reference})

    receive do
      {:workspace_guard_closed, ^reference} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :ok
    after
      5_000 ->
        Process.exit(pid, :kill)
        :ok
    end
  end

  defp loop(workspace, monitor) do
    receive do
      {:close, caller, reference} ->
        _ = SchemaWorkspace.close(workspace)
        send(caller, {:workspace_guard_closed, reference})

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        _ = SchemaWorkspace.close(workspace)

      _message ->
        loop(workspace, monitor)
    end
  end
end
