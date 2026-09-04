defmodule Jido.Harness.Examples.PolicyJob do
  @moduledoc """
  Runs one bounded turn through Session and answers approvals with host policy.

  The turn budget begins after session startup. Policy failures, invalid replies,
  and policy timeouts deny access. Load this example with Code.require_file/1.
  Policy handles permission requests sent by the provider. Configure the provider
  to request approval for the operations that need host review.
  """

  alias Jido.Harness.Session

  def run(provider, prompt, policy, options \\ []) when is_function(policy, 1) do
    timeout = Keyword.get(options, :timeout_ms, 5_000)
    policy_timeout = Keyword.get(options, :policy_timeout_ms, 1_000)
    true = is_integer(timeout) and timeout > 0
    true = is_integer(policy_timeout) and policy_timeout > 0

    request =
      options
      |> Keyword.get(:session_options, %{})
      |> Map.new()
      |> Map.merge(%{
        approval_timeout_ms: policy_timeout,
        turn_runtime_timeout_ms: timeout
      })

    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      with {:ok, session_id} <- Session.start(provider, request) do
        try do
          with {:ok, turn_id} <- Session.send_message(session_id, prompt) do
            state = %{
              session_id: session_id,
              turn_id: turn_id,
              cursor: 0,
              deadline: now() + timeout,
              supervisor: supervisor,
              policy: policy,
              policy_timeout: policy_timeout
            }

            await_result(state)
          end
        after
          Session.close(session_id)
        end
      end
    after
      Supervisor.stop(supervisor)
    end
  end

  defp await_result(state) do
    if remaining(state) <= 0 do
      Session.interrupt(state.session_id, state.turn_id)
      {:error, :timeout}
    else
      with {:ok, events} <- Session.replay(state.session_id, cursor: state.cursor, limit: 100) do
        Enum.each(events, &resolve_approval(&1, state))

        cursor =
          case List.last(events) do
            nil -> state.cursor
            event -> event.sequence
          end

        case Session.await(state.session_id, state.turn_id, min(10, remaining(state))) do
          {:error, :timeout} -> await_result(%{state | cursor: cursor})
          result -> result
        end
      end
    end
  end

  defp resolve_approval(%{type: :approval_requested, turn_id: turn_id} = event, %{turn_id: turn_id} = state) do
    task =
      Task.Supervisor.async_nolink(state.supervisor, fn ->
        try do
          state.policy.(event)
        rescue
          _error -> :deny
        catch
          _kind, _reason -> :deny
        end
      end)

    decision =
      case Task.yield(task, min(state.policy_timeout, remaining(state))) do
        {:ok, :approve} ->
          :approve

        _ ->
          Task.shutdown(task, :brutal_kill)
          :deny
      end

    # The Harness timer can resolve the request first. A stale response does
    # not change the decision or create another permission request.
    case Session.respond_approval(state.session_id, event.request_id, decision) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> raise "approval response failed: #{inspect(reason)}"
    end
  end

  defp resolve_approval(_event, _state), do: :ok
  defp remaining(state), do: max(state.deadline - now(), 0)
  defp now, do: System.monotonic_time(:millisecond)
end
