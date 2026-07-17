defmodule Jido.Harness.SessionAdapters.PiRPC do
  @moduledoc false
  @behaviour Jido.Harness.SessionAdapter

  alias Jido.Harness.SessionAdapters.PiRPCTransport

  @impl true
  def open(request, context) do
    DynamicSupervisor.start_child(
      Jido.Harness.SessionTransportSupervisor,
      {PiRPCTransport, {request, context}}
    )
  end

  @impl true
  def send(handle, request, turn_id),
    do: Jido.Harness.SessionAdapter.call(handle, {:send, request, turn_id})

  @impl true
  def interrupt(handle, turn_id),
    do: Jido.Harness.SessionAdapter.call(handle, {:interrupt, turn_id})

  @impl true
  def steer(handle, request, request_id),
    do: Jido.Harness.SessionAdapter.call(handle, {:steer, request, request_id})

  @impl true
  def configure(handle, changes),
    do: Jido.Harness.SessionAdapter.call(handle, {:configure, changes})

  @impl true
  def close(handle), do: Jido.Harness.SessionAdapter.call(handle, :close)
end
