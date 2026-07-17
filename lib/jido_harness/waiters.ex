defmodule Jido.Harness.Waiters do
  @moduledoc false

  @type t :: %{optional(reference()) => %{from: term(), key: term(), monitor: reference()}}

  @doc false
  @spec add(t(), reference(), term(), term()) :: t()
  def add(waiters, request_ref, {pid, _tag} = from, key \\ nil) do
    Map.put(waiters, request_ref, %{from: from, key: key, monitor: Process.monitor(pid)})
  end

  @doc false
  @spec cancel(t(), reference()) :: t()
  def cancel(waiters, request_ref) do
    case Map.pop(waiters, request_ref) do
      {nil, waiters} -> waiters
      {%{monitor: monitor}, waiters} -> demonitor(monitor, waiters)
    end
  end

  @doc false
  @spec drop_monitor(t(), reference()) :: t()
  def drop_monitor(waiters, monitor) do
    Map.reject(waiters, fn {_request_ref, waiter} -> waiter.monitor == monitor end)
  end

  @doc false
  @spec reply(t(), term(), term()) :: t()
  def reply(waiters, key, response) do
    Enum.reduce(waiters, %{}, fn {request_ref, waiter}, remaining ->
      if waiter.key == key do
        Process.demonitor(waiter.monitor, [:flush])
        GenServer.reply(waiter.from, response)
        remaining
      else
        Map.put(remaining, request_ref, waiter)
      end
    end)
  end

  @doc false
  @spec reply_all(t(), term()) :: t()
  def reply_all(waiters, response), do: reply(waiters, nil, response)

  defp demonitor(monitor, waiters) do
    Process.demonitor(monitor, [:flush])
    waiters
  end
end
