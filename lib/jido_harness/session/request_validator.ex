defmodule Jido.Harness.Session.RequestValidator do
  @moduledoc false

  alias Jido.Harness.{Error, SessionCapabilities, SessionRequest, TurnRequest}
  alias Jido.Harness.Session.State

  @configuration_options [:model, :reasoning_effort, :approval_mode, :sandbox_mode]
  @configuration_option_names Map.new(@configuration_options, &{Atom.to_string(&1), &1})

  @doc false
  @spec unsupported(map(), atom()) :: Error.t()
  def unsupported(state, capability) do
    Error.validation("ACP agent does not support capability",
      provider: state.provider,
      details: %{protocol: :acp, capability: capability}
    )
  end

  @doc false
  @spec require_capability(map(), atom()) :: :ok | {:error, Error.t()}
  def require_capability(state, capability) do
    if SessionCapabilities.supported?(state.acp_agent.capabilities, capability) do
      :ok
    else
      {:error, unsupported(state, capability)}
    end
  end

  @doc false
  @spec normalize_configuration(map()) :: {:ok, map()} | {:error, Error.t()}
  def normalize_configuration(changes) do
    Enum.reduce_while(changes, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      normalized_key = normalize_configuration_key(key)

      if normalized_key do
        {:cont, {:ok, Map.put(normalized, normalized_key, value)}}
      else
        {:halt, {:error, Error.validation("unsupported session configuration", details: %{field: key})}}
      end
    end)
  end

  @doc false
  @spec validate_configuration(State.t(), map()) :: {:ok, SessionRequest.t()} | {:error, Error.t()}
  def validate_configuration(state, changes) do
    allowed = state.acp_agent.configuration_options

    case Enum.find(Map.keys(changes), &(&1 not in allowed)) do
      nil ->
        with {:ok, request} <-
               state.request
               |> Map.from_struct()
               |> Map.merge(changes)
               |> SessionRequest.new(),
             :ok <- validate_configured_values(state, changes) do
          {:ok, request}
        end

      field ->
        {:error,
         Error.validation("unsupported session configuration",
           provider: state.provider,
           details: %{field: field}
         )}
    end
  end

  @doc false
  @spec require_configuration_capabilities(map(), map()) :: :ok | {:error, Error.t()}
  def require_configuration_capabilities(state, changes) do
    capabilities = state.acp_agent.capabilities
    model? = Map.has_key?(changes, :model)
    other? = map_size(Map.delete(changes, :model)) > 0

    if (not model? or SessionCapabilities.supported?(capabilities, :dynamic_model)) and
         (not other? or SessionCapabilities.supported?(capabilities, :dynamic_configuration)) do
      :ok
    else
      {:error, unsupported(state, :dynamic_configuration)}
    end
  end

  @doc false
  @spec validate_turn_request(map(), TurnRequest.t()) :: :ok | {:error, Error.t()}
  def validate_turn_request(state, request) do
    capabilities = state.acp_agent.capabilities
    turn_options = transport_options(state.acp_agent.turn_options, state.adapter.spec().normalized_options)

    cond do
      not is_nil(request.output_schema) and not SessionCapabilities.supported?(capabilities, :structured_output) ->
        {:error, unsupported(state, :structured_output)}

      multimodal?(request) and not SessionCapabilities.supported?(capabilities, :multimodal) ->
        {:error, unsupported(state, :multimodal)}

      field = unsupported_turn_option(request, turn_options) ->
        {:error,
         Error.validation("ACP agent does not support turn option",
           provider: state.provider,
           details: %{protocol: :acp, field: field}
         )}

      path = invalid_attachment(state, request) ->
        {:error,
         Error.validation("turn attachment must be an existing file",
           provider: state.provider,
           details: %{path: path}
         )}

      true ->
        validate_turn_provider_options(state, request.provider_options)
    end
  end

  @doc false
  @spec validate_steer_request(State.t(), TurnRequest.t()) :: :ok | {:error, Error.t()}
  def validate_steer_request(state, request) do
    field =
      cond do
        not is_nil(request.reasoning_effort) -> :reasoning_effort
        not is_nil(request.output_schema) -> :output_schema
        map_size(request.provider_options) > 0 -> :provider_options
        true -> nil
      end

    if field do
      {:error,
       Error.validation("ACP agent does not support steering option",
         provider: state.provider,
         details: %{protocol: :acp, field: field}
       )}
    else
      :ok
    end
  end

  defp normalize_configuration_key(key) when is_atom(key) and key in @configuration_options, do: key
  defp normalize_configuration_key(key) when is_binary(key), do: Map.get(@configuration_option_names, key)
  defp normalize_configuration_key(_key), do: nil

  defp validate_turn_provider_options(state, options) do
    supported =
      transport_options(state.acp_agent.turn_provider_options, state.adapter.spec().provider_options)

    supported_strings = Map.new(supported, &{Atom.to_string(&1), &1})

    case Enum.find(Map.keys(options), fn
           key when is_atom(key) -> key not in supported
           key when is_binary(key) -> not Map.has_key?(supported_strings, key)
           _key -> true
         end) do
      nil ->
        :ok

      key ->
        {:error,
         Error.validation("unknown turn provider option",
           provider: state.provider,
           details: %{key: key}
         )}
    end
  end

  defp multimodal?(request) do
    request.attachments != [] or multimodal_content?(request)
  end

  defp unsupported_turn_option(request, supported) do
    cond do
      not is_nil(request.reasoning_effort) and :reasoning_effort not in supported -> :reasoning_effort
      not is_nil(request.output_schema) and :output_schema not in supported -> :output_schema
      request.attachments != [] and :attachments not in supported -> :attachments
      multimodal_content?(request) and :content not in supported -> :content
      true -> nil
    end
  end

  defp multimodal_content?(request) do
    Enum.any?(request.content, fn block -> Map.get(block, :type) not in [:text, "text"] end)
  end

  defp invalid_attachment(state, request) do
    Enum.find(request.attachments, fn path ->
      not File.regular?(Path.expand(path, state.request.cwd))
    end)
  end

  defp transport_options(:adapter, adapter_options), do: adapter_options
  defp transport_options(options, _adapter_options), do: options

  defp validate_configured_values(state, changes) do
    normalized_values = state.adapter.spec().normalized_values

    Enum.reduce_while(changes, :ok, fn {field, value}, :ok ->
      case Map.get(normalized_values, field) do
        nil ->
          {:cont, :ok}

        allowed ->
          if value in allowed do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              Error.validation("unsupported value for session configuration",
                provider: state.provider,
                details: %{field: field, value: value, allowed: allowed}
              )}}
          end
      end
    end)
  end
end
