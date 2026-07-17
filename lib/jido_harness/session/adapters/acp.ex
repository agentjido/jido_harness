defmodule Jido.Harness.SessionAdapters.ACP do
  @moduledoc false
  @behaviour Jido.Harness.SessionAdapter

  alias Jido.Harness.{Event, SessionAdapters.ACPTransport}

  @startup_timeout 30_000

  @impl true
  def open(request, context) do
    case DynamicSupervisor.start_child(
           Jido.Harness.SessionTransportSupervisor,
           {ACPTransport, {request, context}}
         ) do
      {:ok, pid} ->
        case GenServer.call(pid, {:initialize, request}, @startup_timeout) do
          {:ok, provider_session_id} ->
            Jido.Harness.SessionAdapter.emit(
              context.owner,
              Event.new!(
                type: :provider_event,
                provider: context.provider,
                provider_session_id: provider_session_id,
                payload: %{"kind" => "acp_session_ready"}
              )
            )

            {:ok, pid}

          {:error, _reason} = error ->
            DynamicSupervisor.terminate_child(Jido.Harness.SessionTransportSupervisor, pid)
            error
        end

      {:error, _reason} = error ->
        error
    end
  catch
    :exit, reason -> {:error, reason}
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
  def close(handle), do: Jido.Harness.SessionAdapter.call(handle, :close)
end
