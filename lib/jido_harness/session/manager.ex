defmodule Jido.Harness.SessionManager do
  @moduledoc false

  alias Jido.Harness.{Await, CursorStream, Error, ID, Registry, SessionInfo, SessionRequest, SessionWorker}

  @max_replay_limit 10_000

  def start(provider, request) do
    with {:ok, adapter} <- Registry.lookup(provider),
         {:ok, spec} <- Registry.spec(provider),
         {:ok, request, transport_spec} <- resolve_transport(request, spec),
         :ok <- validate_request(request, spec, transport_spec),
         :ok <- validate_transport_version(adapter, Registry.provider_config(provider), transport_spec) do
      id = ID.generate("session")
      config = Registry.provider_config(provider)
      session_adapter = transport_spec.adapter

      case DynamicSupervisor.start_child(
             Jido.Harness.SessionSupervisor,
             {SessionWorker, {id, provider, request, adapter, session_adapter, transport_spec, config}}
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

  defp resolve_transport(%SessionRequest{} = request, spec) do
    transports = spec.session_transports

    selected =
      request.transport || spec.default_session_transport ||
        case transports do
          [transport | _] -> transport.name
          [] -> :managed
        end

    transport_spec =
      Enum.find(transports, &(&1.name == selected)) ||
        if selected == :managed, do: managed_transport(), else: nil

    transport_spec = specialize_transport(transport_spec, spec)

    cond do
      is_nil(transport_spec) ->
        {:error,
         Error.validation("unknown session transport", provider: spec.provider, details: %{transport: selected})}

      transport_spec.capabilities.maturity == :experimental and is_nil(request.transport) ->
        {:error,
         Error.validation("experimental session transport must be selected explicitly",
           provider: spec.provider,
           details: %{transport: selected}
         )}

      true ->
        {:ok, %{request | provider: spec.provider, transport: selected}, transport_spec}
    end
  end

  @manager_fields [
    :provider,
    :cwd,
    :env,
    :metadata,
    :provider_options,
    :transport,
    :turn_runtime_timeout_ms,
    :turn_idle_timeout_ms,
    :session_idle_timeout_ms,
    :approval_timeout_ms,
    :retention
  ]
  @empty_values [nil, [], %{}, :default]

  defp validate_request(%SessionRequest{} = request, spec, transport_spec) do
    normalized_options = inherited_options(transport_spec.session_options, spec.normalized_options)
    provider_option_names = inherited_options(transport_spec.session_provider_options, spec.provider_options)

    env_supported? =
      transport_spec.adapter == Jido.Harness.SessionAdapters.Managed or :env in normalized_options

    unsupported =
      request
      |> Map.from_struct()
      |> Enum.find(fn {field, value} ->
        field not in @manager_fields and field not in normalized_options and value not in @empty_values
      end)

    provider_options = validate_provider_options(request.provider_options, provider_option_names, spec.provider)
    normalized_values = validate_normalized_values(request, spec, normalized_options)

    cond do
      request.env != %{} and not env_supported? ->
        {:error,
         Error.validation("session transport does not support environment overrides",
           provider: spec.provider,
           details: %{transport: transport_spec.name, field: :env}
         )}

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

  defp managed_transport do
    Jido.Harness.SessionTransportSpec.managed()
  end

  defp specialize_transport(%{adapter: Jido.Harness.SessionAdapters.Managed} = transport, spec) do
    configuration_options = Enum.filter(transport.configuration_options, &(&1 in spec.normalized_options))

    capabilities = %{
      transport.capabilities
      | dynamic_model: if(:model in configuration_options, do: transport.capabilities.dynamic_model, else: false),
        dynamic_configuration:
          if(configuration_options == [], do: false, else: transport.capabilities.dynamic_configuration)
    }

    %{transport | capabilities: capabilities, configuration_options: configuration_options}
  end

  defp specialize_transport(transport, _spec), do: transport

  defp validate_transport_version(_adapter, _config, %{minimum_version: nil}), do: :ok

  defp validate_transport_version(adapter, config, transport_spec) do
    with {:ok, status} <- adapter.status(config),
         true <- status.installed,
         true <- status.compatible,
         {:ok, installed} <- extract_version(status.version),
         {:ok, minimum} <- Version.parse(transport_spec.minimum_version),
         ordering when ordering in [:eq, :gt] <- Version.compare(installed, minimum) do
      :ok
    else
      false ->
        {:error,
         Error.validation("session transport requires an installed compatible CLI",
           details: %{transport: transport_spec.name, minimum_version: transport_spec.minimum_version}
         )}

      :lt ->
        {:error,
         Error.validation("session transport CLI version is too old",
           details: %{transport: transport_spec.name, minimum_version: transport_spec.minimum_version}
         )}

      {:error, reason} ->
        {:error,
         Error.validation("could not verify session transport version",
           details: %{transport: transport_spec.name, reason: inspect(reason)}
         )}
    end
  end

  defp extract_version(version) when is_binary(version) do
    case Regex.run(~r/\d+\.\d+\.\d+/, version) do
      [value] -> Version.parse(value)
      _ -> {:error, :unparseable_version}
    end
  end

  defp extract_version(_version), do: {:error, :missing_version}

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
