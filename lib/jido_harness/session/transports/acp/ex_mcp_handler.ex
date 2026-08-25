defmodule Jido.Harness.SessionAdapters.ACP.ExMCPHandler do
  @moduledoc false
  @behaviour ExMCP.ACP.Client.Handler

  @impl true
  def init(opts), do: {:ok, %{transport: Keyword.fetch!(opts, :transport)}}

  @impl true
  def handle_session_update(session_id, update, state) do
    send(state.transport, {:acp_session_update, session_id, update})
    {:ok, state}
  end

  @impl true
  def handle_permission_request(session_id, tool_call, options, state) do
    ref = make_ref()

    send(
      state.transport,
      {:acp_permission_request, self(), ref, session_id, tool_call, options}
    )

    receive do
      {:jido_harness_approval_response, ^ref, outcome} -> {:ok, outcome, state}
    end
  end
end
