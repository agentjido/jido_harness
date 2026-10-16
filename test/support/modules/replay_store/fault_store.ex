defmodule Jido.Harness.ReplayStore.FaultStore do
  @moduledoc false
  @behaviour Jido.Harness.ReplayStore

  @impl true
  def validate_options(_options), do: :ok
  @impl true
  def open(_resource, options), do: {:ok, options}
  @impl true
  def append(%{operation: :append} = state, _record), do: {:error, :timeout, state}
  def append(state, _record), do: {:ok, state}
  @impl true
  def read(%{operation: :raise}, _cursor, _limits), do: raise("storage failure")
  def read(state, _cursor, _limits), do: {:error, :timeout, state}
  @impl true
  def info(_state), do: %{oldest_sequence: nil, latest_sequence: 0, retained_bytes: 0, retained_events: 0}
  @impl true
  def close(_state), do: :ok
  @impl true
  def delete(%{operation: :delete}), do: {:error, :eacces}
  def delete(_state), do: :ok
end
