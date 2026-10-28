defmodule Jido.Harness.Run.ACP do
  @moduledoc false

  alias Jido.Harness.{ApprovalResponse, Error, ID, RunRequest, SessionRequest, TurnRequest}
  alias Jido.Harness.Adapter.Message
  alias Jido.Harness.SessionAdapters.ACP

  @session_fields [
    :provider,
    :cwd,
    :model,
    :provider_session_id,
    :system_prompt,
    :allowed_tools,
    :disallowed_tools,
    :add_dirs,
    :mcp_config,
    :approval_mode,
    :sandbox_mode,
    :reasoning_effort,
    :env,
    :env_mode,
    :metadata,
    :acp_path
  ]

  @doc false
  def prepare(%RunRequest{} = request, spec, acp_agent) do
    with :ok <- validate_finite_options(request, spec.provider),
         {:ok, session_options, turn_options} <- split_provider_options(request.provider_options, spec, acp_agent),
         {:ok, session_request} <- build_session_request(request, session_options),
         {:ok, turn_request} <- build_turn_request(request, turn_options) do
      {:ok, session_request, turn_request}
    end
  end

  @doc false
  def stream(%SessionRequest{} = session_request, %TurnRequest{} = turn_request, context) do
    context =
      context
      |> Map.put(:owner, self())
      |> Map.put(:session_id, context.run_id)

    with {:ok, handle} <- ACP.open(session_request, context),
         turn_id = ID.generate("turn"),
         :ok <- ACP.send(handle, turn_request, turn_id) do
      monitor = Process.monitor(handle)

      {:ok,
       Stream.resource(
         fn -> %{handle: handle, monitor: monitor, approval_mode: session_request.approval_mode, done?: false} end,
         &next_event/1,
         &close/1
       )}
    end
  end

  defp build_session_request(request, provider_options) do
    request
    |> Map.from_struct()
    |> Map.take(@session_fields)
    |> Map.put(:provider_options, provider_options)
    |> Map.put(:turn_runtime_timeout_ms, request.runtime_timeout_ms)
    |> Map.put(:turn_idle_timeout_ms, request.idle_timeout_ms)
    |> Map.put(:approval_timeout_ms, request.approval_timeout_ms)
    |> SessionRequest.new()
  end

  defp build_turn_request(request, provider_options) do
    attrs = %{
      prompt: request.prompt,
      attachments: request.attachments,
      metadata: request.metadata,
      provider_options: provider_options
    }

    attrs =
      case request.structured_output do
        nil -> attrs
        output -> Map.put(attrs, :output_schema, output.schema)
      end

    TurnRequest.new(attrs)
  end

  defp validate_finite_options(%{approval_mode: :prompt}, provider) do
    {:error,
     Error.validation("prompt approvals require a stateful session",
       provider: provider,
       details: %{field: :approval_mode, protocol: :acp}
     )}
  end

  defp validate_finite_options(%{max_turns: nil}, _provider), do: :ok

  defp validate_finite_options(_request, provider) do
    {:error,
     Error.validation("ACP runs do not support max_turns",
       provider: provider,
       details: %{field: :max_turns, protocol: :acp}
     )}
  end

  defp split_provider_options(options, spec, acp_agent) do
    session_names = inherited_options(acp_agent.session_provider_options, spec.provider_options)
    turn_names = inherited_options(acp_agent.turn_provider_options, spec.provider_options)

    Enum.reduce_while(options, {:ok, %{}, %{}}, fn {key, value}, {:ok, session, turn} ->
      normalized = normalize_option_name(key, spec.provider_options)

      cond do
        normalized in session_names ->
          {:cont, {:ok, Map.put(session, key, value), turn}}

        normalized in turn_names ->
          {:cont, {:ok, session, Map.put(turn, key, value)}}

        true ->
          {:halt,
           {:error,
            Error.validation("unknown ACP provider option",
              provider: spec.provider,
              details: %{key: key, protocol: :acp}
            )}}
      end
    end)
  end

  defp inherited_options(:adapter, options), do: options
  defp inherited_options(options, _adapter_options), do: options

  defp normalize_option_name(key, _known) when is_atom(key), do: key

  defp normalize_option_name(key, known) when is_binary(key) do
    Enum.find(known, &(Atom.to_string(&1) == key))
  end

  defp normalize_option_name(_key, _known), do: nil

  defp next_event(%{done?: true} = state), do: {:halt, state}

  defp next_event(state) do
    receive do
      {:session_adapter_message, %Message{type: :approval_requested} = message} ->
        response = approval_response(state.approval_mode)

        case ACP.respond_approval(state.handle, message.request_id, response) do
          :ok ->
            resolved =
              Message.new!(
                type: :approval_resolved,
                provider_session_id: message.provider_session_id,
                turn_id: message.turn_id,
                request_id: message.request_id,
                payload: %{
                  "decision" => Atom.to_string(response.decision),
                  "scope" => Atom.to_string(response.scope)
                }
              )

            {[message, resolved], state}

          {:error, reason} ->
            {[run_failed(message, "could not resolve ACP approval", reason)], %{state | done?: true}}
        end

      {:session_adapter_message, %Message{} = message} ->
        case run_message(message) do
          %Message{type: type} = run_message when type in [:run_completed, :run_failed, :run_cancelled] ->
            {[run_message], %{state | done?: true}}

          run_message ->
            {[run_message], state}
        end

      {:DOWN, monitor, :process, handle, reason} when monitor == state.monitor and handle == state.handle ->
        message = Message.new!(type: :run_failed, payload: %{"error" => inspect(reason)})
        {[message], %{state | done?: true}}
    end
  end

  defp run_message(%Message{type: :turn_completed} = message), do: %{message | type: :run_completed}
  defp run_message(%Message{type: :turn_interrupted} = message), do: %{message | type: :run_cancelled}
  defp run_message(%Message{type: :turn_failed} = message), do: %{message | type: :run_failed}
  defp run_message(message), do: message

  defp run_failed(adapter_message, message, reason) do
    %{
      adapter_message
      | type: :run_failed,
        request_id: nil,
        payload: %{"error" => message, "reason" => inspect(reason)}
    }
  end

  defp approval_response(:auto_approve),
    do: ApprovalResponse.new!(decision: :approve, scope: :once)

  defp approval_response(_mode), do: ApprovalResponse.new!(decision: :deny, scope: :once)

  defp close(state) do
    Process.demonitor(state.monitor, [:flush])
    _ = ACP.close(state.handle)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
