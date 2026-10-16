defmodule Jido.Harness.Waiters do
  @moduledoc false

  @type t :: map()

  @doc false
  @spec add(t(), reference(), term(), term()) :: t()
  def add(waiters, request_ref, {pid, _tag} = from, key \\ nil) do
    waiters = cancel(waiters, request_ref)
    monitor = Process.monitor(pid)

    waiters
    |> Map.put(request_ref, %{from: from, key: key, monitor: monitor})
    |> Map.put({:monitor, monitor}, request_ref)
    |> Map.update({:key, key}, MapSet.new([request_ref]), &MapSet.put(&1, request_ref))
  end

  @doc false
  @spec cancel(t(), reference()) :: t()
  def cancel(waiters, request_ref) do
    case Map.pop(waiters, request_ref) do
      {nil, waiters} ->
        waiters

      {%{monitor: monitor, key: key}, waiters} ->
        Process.demonitor(monitor, [:flush])
        refs = waiters |> Map.fetch!({:key, key}) |> MapSet.delete(request_ref)
        waiters = Map.delete(waiters, {:monitor, monitor})
        if MapSet.size(refs) == 0, do: Map.delete(waiters, {:key, key}), else: Map.put(waiters, {:key, key}, refs)
    end
  end

  @doc false
  @spec drop_monitor(t(), reference()) :: t()
  def drop_monitor(waiters, monitor) do
    case Map.fetch(waiters, {:monitor, monitor}) do
      {:ok, request_ref} -> cancel(waiters, request_ref)
      :error -> waiters
    end
  end

  @doc false
  @spec reply(t(), term(), term()) :: t()
  def reply(waiters, key, response) do
    Enum.reduce(Map.get(waiters, {:key, key}, MapSet.new()), waiters, fn request_ref, remaining ->
      GenServer.reply(Map.fetch!(remaining, request_ref).from, response)
      cancel(remaining, request_ref)
    end)
  end

  @doc false
  @spec reply_all(t(), term()) :: t()
  def reply_all(waiters, response), do: reply(waiters, nil, response)
end
