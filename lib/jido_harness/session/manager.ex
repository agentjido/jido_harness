defmodule Jido.Harness.SessionManager do
  @moduledoc false

  alias Jido.Harness.{Await, CursorStream, Error, ID, Registry, SessionInfo, SessionRequest, SessionWorker}

  @max_replay_limit 10_000

  def start(provider, request) do
    with {:ok, adapter} <- Registry.lookup(provider),
         {:ok, spec} <- Registry.spec(provider),
         {:ok, acp_agent} <- require_acp_agent(spec),
         request = %{request | provider: spec.provider},
         :ok <- validate_request(request, spec, acp_agent) do
      id = ID.generate("session")
      config = Registry.provider_config(provider)

      case DynamicSupervisor.start_child(
             Jido.Harness.SessionSupervisor,
             {SessionWorker, {id, provider, request, adapter, acp_agent, config}}
           ) do
        {:ok, _pid} ->
          {:ok, id}

        {:error, reason} ->
          {:error,
           Error.execution("could not start harness session", provider: provider, details: %{reason: inspect(reason)})}
      end
    end
  end

  def info(id), do: call(id, :info)

  def list(filters \\ []) do
    providers = Keyword.get(filters, :providers)
    states = Keyword.get(filters, :states)

    Jido.Harness.SessionRegistry
    |> Elixir.Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn id ->
      case info(id) do
        {:ok, info} -> [info]
        _ -> []
      end
    end)
    |> Enum.filter(fn info ->
      (is_nil(providers) or info.provider in providers) and (is_nil(states) or info.state in states)
    end)
  end

  def replay(id, options \\ []) do
    with {:ok, options} <- Jido.Harness.Validation.keyword_options(options),
         cursor = Keyword.get(options, :cursor, 0),
         limit = Keyword.get(options, :limit, 100),
         :ok <- validate_replay(cursor, limit),
         do: call(id, {:replay, cursor, limit})
  end

  def stream(id, options \\ []) do
    with {:ok, options} <- Jido.Harness.Validation.keyword_options(options),
         {:ok, _info} <- info(id) do
      {:ok,
       CursorStream.build(
         &replay(id, cursor: &1, limit: &2),
         fn -> info(id) end,
         &SessionInfo.terminal?/1,
         options
       )}
    end
  end

  def send_message(id, request), do: call(id, {:send_message, request})
  def follow_up(id, request), do: call(id, {:follow_up, request})
  def steer(id, request), do: call(id, {:steer, request})
  def interrupt(id, turn_id), do: call(id, {:interrupt, turn_id})
  def respond_approval(id, request_id, response), do: call(id, {:respond_approval, request_id, response})
  def configure(id, changes), do: call(id, {:configure, changes})
  def close(id), do: call(id, :close)
  def kill(id), do: call(id, :kill)
  def prune(id), do: call(id, :prune)

  def await_turn(id, turn_id, timeout \\ :infinity) do
    with :ok <- Jido.Harness.Validation.await_timeout(timeout) do
      case call(id, {:turn_result, turn_id}) do
        {:ok, result} -> {:ok, result}
        {:pending, _info} when timeout == 0 -> {:error, :timeout}
        {:pending, _info} -> Await.call(Jido.Harness.SessionRegistry, id, &{:await_turn, &1, turn_id}, timeout)
        error -> error
      end
    end
  end

  defp call(id, message) do
    case Elixir.Registry.lookup(Jido.Harness.SessionRegistry, id) do
      [{pid, _value}] ->
        try do
          GenServer.call(pid, message, :infinity)
        catch
          :exit, {:noproc, _} -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp require_acp_agent(%{acp_agent: %Jido.Harness.ACPAgentSpec{} = acp_agent}), do: {:ok, acp_agent}

  defp require_acp_agent(spec) do
    {:error, Error.validation("provider does not expose an ACP agent", provider: spec.provider)}
  end

  @manager_fields [
    :provider,
    :cwd,
    :env,
    :env_mode,
    :metadata,
    :provider_options,
    :acp_path,
    :turn_runtime_timeout_ms,
    :turn_idle_timeout_ms,
    :session_idle_timeout_ms,
    :approval_timeout_ms,
    :retention
  ]
  @empty_values [nil, [], %{}, :default]

  @doc false
  def validate_request(%SessionRequest{} = request, spec, acp_agent) do
    normalized_options =
      acp_agent.session_options
      |> inherited_options(spec.normalized_options)
      |> Kernel.++(acp_agent.configuration_options)
      |> Enum.uniq()

    provider_option_names = inherited_options(acp_agent.session_provider_options, spec.provider_options)

    unsupported =
      request
      |> Map.from_struct()
      |> Enum.find(fn {field, value} ->
        field not in @manager_fields and field not in normalized_options and value not in @empty_values
      end)

    provider_options = validate_provider_options(request.provider_options, provider_option_names, spec.provider)
    normalized_values = validate_normalized_values(request, spec, normalized_options)

    cond do
      not is_nil(request.provider_session_id) and not acp_agent.capabilities.load_session ->
        {:error,
         Error.validation("ACP agent does not support session loading",
           provider: spec.provider,
           details: %{capability: :load_session}
         )}

      not is_nil(request.mcp_config) and not acp_agent.capabilities.mcp ->
        {:error, Error.validation("ACP agent does not support MCP servers", provider: spec.provider)}

      unsupported ->
        {field, _value} = unsupported

        {:error,
         Error.validation("provider does not support normalized session option",
           provider: spec.provider,
           details: %{field: field}
         )}

      match?({:error, _}, provider_options) ->
        provider_options

      match?({:error, _}, normalized_values) ->
        normalized_values

      true ->
        :ok
    end
  end

  defp inherited_options(:adapter, adapter_options), do: adapter_options
  defp inherited_options(options, _adapter_options), do: options

  defp validate_normalized_values(request, spec, supported) do
    Enum.reduce_while(spec.normalized_values, :ok, fn {field, allowed}, :ok ->
      value = Map.get(request, field)

      if field not in supported or value in @empty_values or value in allowed do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          Error.validation("unsupported value for normalized session option",
            provider: spec.provider,
            details: %{field: field, value: value, allowed: allowed}
          )}}
      end
    end)
  end

  defp validate_provider_options(options, supported, provider) do
    supported_strings = Map.new(supported, &{Atom.to_string(&1), &1})

    Enum.reduce_while(options, :ok, fn
      {key, _value}, :ok when is_atom(key) ->
        if key in supported,
          do: {:cont, :ok},
          else: {:halt, {:error, Error.validation("unknown provider option", provider: provider, details: %{key: key})}}

      {key, _value}, :ok when is_binary(key) ->
        if Map.has_key?(supported_strings, key),
          do: {:cont, :ok},
          else: {:halt, {:error, Error.validation("unknown provider option", provider: provider, details: %{key: key})}}

      {key, _value}, :ok ->
        {:halt, {:error, Error.validation("unknown provider option", provider: provider, details: %{key: key})}}
    end)
  end

  defp validate_replay(cursor, limit)
       when is_integer(cursor) and cursor >= 0 and is_integer(limit) and limit > 0 and limit <= @max_replay_limit,
       do: :ok

  defp validate_replay(cursor, limit),
    do:
      {:error,
       Error.validation("invalid replay cursor or limit",
         details: %{cursor: cursor, limit: limit, max_limit: @max_replay_limit}
       )}
end
