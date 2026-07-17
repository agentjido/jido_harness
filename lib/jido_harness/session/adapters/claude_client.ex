defmodule Jido.Harness.SessionAdapters.ClaudeClient do
  @moduledoc false
  @behaviour Jido.Harness.SessionAdapter

  alias Jido.Harness.SessionAdapters.ClaudeClientTransport

  @impl true
  def open(request, context) do
    DynamicSupervisor.start_child(
      Jido.Harness.SessionTransportSupervisor,
      {ClaudeClientTransport, {request, context}}
    )
  end

  @impl true
  def send(handle, request, turn_id),
    do: Jido.Harness.SessionAdapter.call(handle, {:send, request, turn_id})

  @impl true
  def interrupt(handle, turn_id),
    do: Jido.Harness.SessionAdapter.call(handle, {:interrupt, turn_id})

  @impl true
  def respond_approval(handle, request_id, response),
    do: Jido.Harness.SessionAdapter.call(handle, {:respond_approval, {request_id, response}})

  @impl true
  def configure(handle, changes),
    do: Jido.Harness.SessionAdapter.call(handle, {:configure, changes})

  @impl true
  def close(handle), do: Jido.Harness.SessionAdapter.call(handle, :close)
end
