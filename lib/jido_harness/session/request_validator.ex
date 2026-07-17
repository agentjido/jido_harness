defmodule Jido.Harness.Session.RequestValidator do
  @moduledoc false

  alias Jido.Harness.{Error, InteractionCapabilities, SessionRequest, TurnRequest}
  alias Jido.Harness.Session.State

  @configuration_options [:model, :reasoning_effort, :approval_mode, :sandbox_mode]
  @configuration_option_names Map.new(@configuration_options, &{Atom.to_string(&1), &1})

  @doc false
  @spec unsupported(State.t(), atom()) :: Error.t()
  def unsupported(state, capability) do
    Error.validation("session transport does not support capability",
      provider: state.provider,
      details: %{transport: state.transport_spec.name, capability: capability}
    )
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
    allowed = state.transport_spec.configuration_options

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
  @spec configuration_supported?(Jido.Harness.InteractionCapabilities.t(), map()) :: boolean()
  def configuration_supported?(capabilities, changes) do
    model? = Map.has_key?(changes, :model)

    (not model? or InteractionCapabilities.supported?(capabilities, :dynamic_model)) and
      InteractionCapabilities.supported?(capabilities, :dynamic_configuration)
  end

  @doc false
  @spec validate_turn_request(State.t(), TurnRequest.t()) :: :ok | {:error, Error.t()}
  def validate_turn_request(state, request) do
    capabilities = state.transport_spec.capabilities
    turn_options = transport_options(state.transport_spec.turn_options, state.adapter.spec().normalized_options)

    cond do
      not is_nil(request.output_schema) and not InteractionCapabilities.supported?(capabilities, :structured_output) ->
        {:error, unsupported(state, :structured_output)}

      multimodal?(request) and not InteractionCapabilities.supported?(capabilities, :multimodal) ->
        {:error, unsupported(state, :multimodal)}

      field = unsupported_turn_option(request, turn_options) ->
        {:error,
         Error.validation("session transport does not support turn option",
           provider: state.provider,
           details: %{transport: state.transport_spec.name, field: field}
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
       Error.validation("session transport does not support steering option",
         provider: state.provider,
         details: %{transport: state.transport_spec.name, field: field}
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
      transport_options(state.transport_spec.turn_provider_options, state.adapter.spec().provider_options)

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
