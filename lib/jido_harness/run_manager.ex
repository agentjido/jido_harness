defmodule Jido.Harness.RunManager do
  @moduledoc false

  alias Jido.Harness.{CursorStream, ID, Registry, RunInfo, RunWorker}

  def start(provider, request) do
    with {:ok, adapter} <- Registry.lookup(provider) do
      id = ID.generate("run")
      config = Registry.provider_config(provider)

      case DynamicSupervisor.start_child(
             Jido.Harness.RunSupervisor,
             {RunWorker, {id, provider, request, adapter, config}}
           ) do
        {:ok, _pid} ->
          {:ok, id}

        {:error, reason} ->
          {:error,
           Jido.Harness.Error.execution("could not start harness run",
             provider: provider,
             details: %{reason: inspect(reason)}
           )}
      end
    end
  end

  def info(id), do: call(id, :info)

  def list(filters \\ []) do
    providers = Keyword.get(filters, :providers)
    states = Keyword.get(filters, :states)

    Jido.Harness.RunRegistry
    |> Elixir.Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn id ->
      case info(id) do
        {:ok, info} -> [info]
        _ -> []
      end
    end)
    |> Enum.filter(fn info ->
      (is_nil(providers) or info.provider in providers) and (is_nil(states) or info.state in states)
    end)
  end

  def replay(id, options \\ []) do
    cursor = Keyword.get(options, :cursor, 0)
    limit = Keyword.get(options, :limit, 100)
    call(id, {:replay, cursor, limit})
  end

  def stream(id, options \\ []) do
    with {:ok, _info} <- info(id) do
      {:ok, CursorStream.build(&replay(id, cursor: &1, limit: &2), fn -> info(id) end, &RunInfo.terminal?/1, options)}
    end
  end

  def await(id, timeout \\ :infinity), do: await_result(id, timeout, System.monotonic_time(:millisecond))
  def cancel(id), do: call(id, :cancel)
  def prune(id), do: call(id, :prune)

  defp await_result(id, timeout, started) do
    case call(id, :result) do
      {:ok, result} ->
        {:ok, result}

      {:pending, _info} ->
        if timeout != :infinity and System.monotonic_time(:millisecond) - started >= timeout do
          {:error, :timeout}
        else
          Process.sleep(25)
          await_result(id, timeout, started)
        end

      error ->
        error
    end
  end

  defp call(id, message) do
    case Elixir.Registry.lookup(Jido.Harness.RunRegistry, id) do
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
end
