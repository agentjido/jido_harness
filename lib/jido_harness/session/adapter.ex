defmodule Jido.Harness.SessionAdapter do
  @moduledoc "Behaviour for provider transports that back interactive sessions."

  alias Jido.Harness.{ApprovalResponse, Event, SessionRequest, TurnRequest}

  @type context :: %{
          required(:session_id) => String.t(),
          required(:provider) => atom(),
          required(:owner) => pid(),
          required(:adapter) => module(),
          required(:config) => map(),
          required(:process_manager) => module(),
          required(:telemetry_context) => map()
        }

  @type handle :: pid() | term()

  @callback open(SessionRequest.t(), context()) :: {:ok, handle()} | {:error, term()}
  @callback send(handle(), TurnRequest.t(), String.t()) :: :ok | {:error, term()}
  @callback interrupt(handle(), String.t() | :active) :: :ok | {:error, term()}
  @callback close(handle()) :: :ok | {:error, term()}
  @callback steer(handle(), TurnRequest.t(), String.t()) :: :ok | {:error, term()}
  @callback respond_approval(handle(), String.t(), ApprovalResponse.t()) :: :ok | {:error, term()}
  @callback configure(handle(), map()) :: :ok | {:error, term()}

  @optional_callbacks steer: 3, respond_approval: 3, configure: 2

  @doc false
  @spec emit(pid(), Event.t()) :: :ok
  def emit(owner, %Event{} = event) when is_pid(owner) do
    send(owner, {:session_adapter_event, event})
    :ok
  end

  @doc false
  @spec call(handle(), term(), timeout()) :: term() | {:error, {:transport_exit, term()}}
  def call(handle, message, timeout \\ :infinity) do
    GenServer.call(handle, message, timeout)
  catch
    :exit, reason -> {:error, {:transport_exit, reason}}
  end
end
