defmodule Jido.Harness.SessionAdapters.Managed do
  @moduledoc false
  @behaviour Jido.Harness.SessionAdapter

  alias Jido.Harness.SessionAdapters.ManagedTransport

  @impl true
  def open(request, context) do
    DynamicSupervisor.start_child(
      Jido.Harness.SessionTransportSupervisor,
      {ManagedTransport, {request, context}}
    )
  end

  @impl true
  def send(handle, request, turn_id),
    do: Jido.Harness.SessionAdapter.call(handle, {:send, request, turn_id})

  @impl true
  def interrupt(handle, turn_id),
    do: Jido.Harness.SessionAdapter.call(handle, {:interrupt, turn_id})

  @impl true
  def close(handle), do: Jido.Harness.SessionAdapter.call(handle, :close)

  @impl true
  def configure(handle, changes),
    do: Jido.Harness.SessionAdapter.call(handle, {:configure, changes})
end
