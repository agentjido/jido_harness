defmodule Jido.Harness.RunManager do
  @moduledoc false

  alias Jido.Harness.{Await, CursorStream, ID, Registry, RunInfo, RunWorker}

  @max_replay_limit 10_000

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
    with {:ok, options} <- Jido.Harness.Validation.keyword_options(options),
         cursor = Keyword.get(options, :cursor, 0),
         limit = Keyword.get(options, :limit, 100),
         :ok <- validate_replay(cursor, limit) do
      call(id, {:replay, cursor, limit})
    end
  end

  def stream(id, options \\ []) do
    with {:ok, options} <- Jido.Harness.Validation.keyword_options(options),
         {:ok, _info} <- info(id) do
      {:ok, CursorStream.build(&replay(id, cursor: &1, limit: &2), fn -> info(id) end, &RunInfo.terminal?/1, options)}
    end
  end

  def await(id, timeout \\ :infinity) do
    with :ok <- Jido.Harness.Validation.await_timeout(timeout) do
      case call(id, :result) do
        {:ok, result} -> {:ok, result}
        {:pending, _info} when timeout == 0 -> {:error, :timeout}
        {:pending, _info} -> Await.call(Jido.Harness.RunRegistry, id, &{:await, &1}, timeout)
        error -> error
      end
    end
  end

  def cancel(id), do: call(id, :cancel)
  def prune(id), do: call(id, :prune)

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
