defmodule Jido.Harness.SessionAdapters.SDKRuntime do
  @moduledoc false
  @behaviour Jido.Harness.SessionAdapter

  alias Jido.Harness.SessionAdapters.SDKRuntimeTransport

  @impl true
  def open(request, context) do
    DynamicSupervisor.start_child(
      Jido.Harness.SessionTransportSupervisor,
      {SDKRuntimeTransport, {request, context}}
    )
  end

  @impl true
  def send(handle, request, turn_id),
    do: Jido.Harness.SessionAdapter.call(handle, {:send, request, turn_id})

  @impl true
  def interrupt(handle, turn_id),
    do: Jido.Harness.SessionAdapter.call(handle, {:interrupt, turn_id})

  @impl true
  def steer(handle, request, _request_id),
    do: Jido.Harness.SessionAdapter.call(handle, {:steer, request})

  @impl true
  def close(handle), do: Jido.Harness.SessionAdapter.call(handle, :close)
end
