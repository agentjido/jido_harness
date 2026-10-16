defmodule Jido.Harness.ReplayStore.FaultStore do
  @moduledoc false
  @behaviour Jido.Harness.ReplayStore

  @impl true
  def validate_options(_options), do: :ok
  @impl true
  def open(_resource, %{operation: :invalid_open}), do: :bad_result
  def open(_resource, %{operation: :nil_handle}), do: {:ok, nil}
  def open(_resource, options), do: {:ok, options}
  @impl true
  def append(%{operation: :append} = state, _record), do: {:error, :timeout, state}
  def append(%{operation: :invalid_append}, _record), do: :bad_result

  def append(nil, _record) do
    send(self(), :opaque_append)
    {:ok, nil}
  end

  def append(state, _record), do: {:ok, state}
  @impl true
  def read(%{operation: :raise}, _cursor, _limits), do: raise("storage failure")
  def read(%{operation: :invalid_read}, _cursor, _limits), do: :bad_result
  def read(%{page: page} = state, _cursor, _limits), do: {:ok, page, state}
  def read(state, _cursor, _limits), do: {:error, :timeout, state}
  @impl true
  def info(%{operation: :invalid_info}), do: %{latest_sequence: "invalid"}
  def info(_state), do: %{oldest_sequence: nil, latest_sequence: 0, retained_bytes: 0, retained_events: 0}
  @impl true
  def close(%{operation: :invalid_close}), do: :bad_result
  def close(_state), do: :ok
  @impl true
  def delete(%{operation: :delete}), do: {:error, :eacces}
  def delete(%{operation: :invalid_delete}), do: :bad_result

  def delete(nil) do
    send(self(), :opaque_delete)
    :ok
  end

  def delete(_state), do: :ok
end
