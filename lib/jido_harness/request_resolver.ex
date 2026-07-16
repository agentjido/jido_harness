defmodule Jido.Harness.RequestResolver do
  @moduledoc false

  alias Jido.Harness.{AdapterSpec, Error, Registry, RunRequest}

  @manager_fields [:prompt, :provider, :cwd, :runtime_timeout_ms, :idle_timeout_ms, :env, :metadata, :provider_options]
  @empty_values [nil, [], %{}, :default]

  def resolve(provider, %RunRequest{} = request) do
    with {:ok, spec} <- Registry.spec(provider),
         :ok <- validate_supported(request, spec) do
      {:ok, %{request | provider: provider}}
    end
  end

  def resolve(provider, attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, spec} <- Registry.spec(provider) do
      config_defaults = Registry.provider_config(provider) |> Map.get(:request_defaults, %{}) |> Map.new()

      explicit =
        attrs
        |> Map.new()
        |> Map.delete(:provider)
        |> Map.delete("provider")

      merged =
        spec.request_defaults
        |> Map.merge(config_defaults)
        |> Map.merge(explicit)
        |> Map.put(:provider, provider)

      with {:ok, request} <- RunRequest.new(merged),
           :ok <- validate_supported(request, spec) do
        {:ok, request}
      end
    end
  end

  defp validate_supported(request, %AdapterSpec{} = spec) do
    unsupported =
      request
      |> Map.from_struct()
      |> Enum.find(fn {field, value} ->
        field not in @manager_fields and field not in spec.normalized_options and value not in @empty_values
      end)

    provider_options = normalize_provider_option_keys(request.provider_options, spec.provider_options)
    unsupported_value = unsupported_normalized_value(request, spec.normalized_values)

    cond do
      unsupported ->
        {field, _value} = unsupported

        {:error,
         Error.validation("provider does not support normalized option",
           provider: spec.provider,
           details: %{field: field}
         )}

      unsupported_value ->
        {field, value} = unsupported_value

        {:error,
         Error.validation("provider does not support normalized option value",
           provider: spec.provider,
           details: %{field: field, value: value}
         )}

      match?({:error, _}, provider_options) ->
        provider_options

      true ->
        :ok
    end
  end

  defp unsupported_normalized_value(request, constraints) do
    Enum.find_value(constraints, fn {field, accepted} ->
      value = Map.fetch!(request, field)
      if value in accepted, do: nil, else: {field, value}
    end)
  end

  defp normalize_provider_option_keys(options, supported) do
    supported_strings = Map.new(supported, &{Atom.to_string(&1), &1})

    Enum.reduce_while(options, :ok, fn
      {key, _value}, :ok when is_atom(key) ->
        if key in supported, do: {:cont, :ok}, else: {:halt, unknown_provider_option(key)}

      {key, _value}, :ok when is_binary(key) ->
        if Map.has_key?(supported_strings, key), do: {:cont, :ok}, else: {:halt, unknown_provider_option(key)}

      {key, _value}, :ok ->
        {:halt, unknown_provider_option(key)}
    end)
  end

  defp unknown_provider_option(key), do: {:error, Error.validation("unknown provider option", details: %{key: key})}
end
