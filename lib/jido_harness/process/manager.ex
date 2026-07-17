defmodule Jido.Harness.ProcessManager do
  @moduledoc false

  alias Jido.Harness.{Await, CursorStream, ID, ProcessInfo, ProcessSpec, ProcessWorker}

  @max_replay_limit 10_000

  @spec start_process(map() | keyword() | ProcessSpec.t()) :: {:ok, String.t()} | {:error, term()}
  @doc "Starts a temporary supervised worker for a structured process specification."
  def start_process(spec) do
    with {:ok, spec} <- ProcessSpec.new(spec) do
      start_worker(spec)
    end
  end

  @doc false
  def start_owned_process(spec, owner) when is_pid(owner) do
    with {:ok, spec} <- ProcessSpec.new(spec) do
      start_worker(%{spec | lifecycle_owner: owner})
    end
  end

  defp start_worker(spec) do
    id = ID.generate("proc")

    case DynamicSupervisor.start_child(Jido.Harness.ProcessSupervisor, {ProcessWorker, {id, spec}}) do
      {:ok, _pid} ->
        {:ok, id}

      {:error, reason} ->
        {:error,
         Jido.Harness.Error.new(:process, "could not start managed process", details: %{reason: inspect(reason)})}
    end
  end

  @doc "Returns a redacted process snapshot by stable process ID."
  def info_process(id), do: call(id, :info)

  @doc "Lists managed processes, optionally filtering with `states: [...]`."
  def list_processes(filters \\ []) do
    states = Keyword.get(filters, :states)

    Jido.Harness.ProcessRegistry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn id ->
      case info_process(id) do
        {:ok, info} -> [info]
        _ -> []
      end
    end)
    |> Enum.filter(fn info -> is_nil(states) or info.state in states end)
  end

  @doc "Returns up to `limit` retained events after the supplied cursor."
  def replay_process(id, options \\ []) do
    with {:ok, options} <- Jido.Harness.Validation.keyword_options(options),
         cursor = Keyword.get(options, :cursor, 0),
         limit = Keyword.get(options, :limit, 100),
         :ok <- validate_replay(cursor, limit) do
      call(id, {:replay, cursor, limit})
    end
  end

  @doc "Returns a pull-based process event stream starting at an optional cursor."
  def stream_process(id, options \\ []) do
    with {:ok, options} <- Jido.Harness.Validation.keyword_options(options),
         {:ok, _info} <- info_process(id) do
      {:ok,
       CursorStream.build(
         &replay_process(id, cursor: &1, limit: &2),
         fn -> info_process(id) end,
         &ProcessInfo.terminal?/1,
         options
       )}
    end
  end

  @doc "Waits for termination without cancelling the process when the wait times out."
  def await_process(id, timeout \\ :infinity) do
    with :ok <- Jido.Harness.Validation.await_timeout(timeout) do
      case info_process(id) do
        {:ok, info} when timeout == 0 ->
          if ProcessInfo.terminal?(info), do: {:ok, info}, else: {:error, :timeout}

        {:ok, info} ->
          if ProcessInfo.terminal?(info) do
            {:ok, info}
          else
            Await.call(Jido.Harness.ProcessRegistry, id, &{:await, &1}, timeout)
          end

        error ->
          error
      end
    end
  end

  @doc "Writes binary data to the process's standard input."
  def send_input(id, data) when is_binary(data), do: call(id, {:input, data})

  def send_input(_id, _data),
    do: {:error, Jido.Harness.Error.validation("process input must be binary data")}

  @doc "Closes standard input, or sends the PTY end-of-input character."
  def close_input(id), do: call(id, {:input, :eof})

  @doc "Begins graceful INT/TERM/KILL process-group cancellation."
  def cancel_process(id), do: call(id, :cancel)

  @doc "Immediately sends KILL to the process group."
  def kill_process(id), do: call(id, :kill)

  @doc "Stops a terminal worker and removes its retained output."
  def prune_process(id), do: call(id, :prune)

  @doc "Builds an explicitly unsafe shell-backed specification. Built-in adapters never call this."
  def unsafe_shell_spec(command, options \\ []) when is_binary(command) do
    with {:ok, options} <- Jido.Harness.Validation.keyword_options(options) do
      shell = System.find_executable("sh") || "/bin/sh"
      options |> Map.new() |> Map.merge(%{executable: shell, argv: ["-c", command]}) |> ProcessSpec.new()
    end
  end

  defp call(id, message) do
    case Registry.lookup(Jido.Harness.ProcessRegistry, id) do
      [{pid, _value}] ->
        try do
          GenServer.call(pid, message, :infinity)
        catch
          :exit, {:noproc, _} -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp validate_replay(cursor, limit)
       when is_integer(cursor) and cursor >= 0 and is_integer(limit) and limit > 0 and limit <= @max_replay_limit,
       do: :ok

  defp validate_replay(cursor, limit) do
    {:error,
     Jido.Harness.Error.validation("invalid replay cursor or limit",
       details: %{cursor: cursor, limit: limit, max_limit: @max_replay_limit}
     )}
  end
end
