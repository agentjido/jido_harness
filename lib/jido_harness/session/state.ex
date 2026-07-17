defmodule Jido.Harness.Session.State do
  @moduledoc false

  @enforce_keys [
    :id,
    :provider,
    :request,
    :adapter,
    :session_adapter,
    :transport_spec,
    :context,
    :started_at,
    :buffer,
    :journal
  ]

  defstruct [
    :id,
    :provider,
    :request,
    :adapter,
    :session_adapter,
    :transport_spec,
    :context,
    :started_at,
    :buffer,
    :journal,
    :handle,
    :handle_monitor,
    :finished_at,
    :provider_session_id,
    :terminal_event,
    :active,
    :error,
    :session_idle_timer,
    :session_idle_token,
    :turn_runtime_timer,
    :turn_runtime_token,
    :turn_idle_timer,
    :turn_idle_token,
    status: :starting,
    sequence: 0,
    queue: {[], []},
    results: %{},
    known_turns: MapSet.new(),
    pending_approvals: %{},
    waiters: %{}
  ]

  @type t :: %__MODULE__{}
end
