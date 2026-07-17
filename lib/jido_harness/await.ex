defmodule Jido.Harness.Await do
  @moduledoc false

  @doc false
  @spec call(module(), term(), (reference() -> term()), timeout()) :: term()
  def call(registry, id, message, timeout) do
    case Registry.lookup(registry, id) do
      [{pid, _value}] -> await(pid, message, timeout)
      [] -> {:error, :not_found}
    end
  end

  defp await(pid, message, timeout) do
    request_ref = make_ref()

    try do
      GenServer.call(pid, message.(request_ref), timeout)
    catch
      :exit, {:timeout, _call} ->
        GenServer.cast(pid, {:cancel_await, request_ref})
        {:error, :timeout}

      :exit, {:noproc, _call} ->
        {:error, :not_found}
    end
  end
end
