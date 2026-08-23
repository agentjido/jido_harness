defmodule Jido.Harness.JSONSchema do
  @moduledoc false

  alias Jido.Harness.Error

  @maximum_bytes 65_536
  @maximum_depth 16
  @maximum_properties 256
  @maximum_enum_values 128
  @maximum_combinators 32
  @types ~w(null boolean object array number integer string)
  @keywords MapSet.new(~w(
    $schema title description type properties required additionalProperties
    items enum const minLength maxLength minimum maximum minItems maxItems
    anyOf oneOf allOf
  ))

  @doc false
  @spec admit(map()) :: :ok | {:error, Error.t()}
  def admit(schema) when is_map(schema) do
    with {:ok, encoded} <- encode(schema),
         :ok <- within(byte_size(encoded), @maximum_bytes, :schema_too_large),
         {:ok, _counts} <- validate_schema(schema, 1, %{properties: 0, enums: 0, combinators: 0}) do
      :ok
    end
  end

  def admit(_schema), do: invalid(:schema_not_object)

  @doc false
  @spec encode(map()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(schema) when is_map(schema) do
    case Jason.encode(canonical(schema)) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> invalid(:schema_not_json)
    end
  rescue
    _exception -> invalid(:schema_not_json)
  end

  @doc false
  @spec validate(term(), map()) :: :ok | {:error, Error.t()}
  def validate(value, schema) when is_map(schema) do
    case validate_value(value, schema) do
      :ok -> :ok
      :error -> invalid(:schema_validation_failed)
    end
  end

  defp validate_schema(schema, depth, counts) when depth <= @maximum_depth do
    with :ok <- string_keys(schema),
         :ok <- supported_keywords(schema),
         :ok <- validate_type(schema),
         :ok <- validate_required(schema),
         :ok <- validate_scalar_limits(schema),
         {:ok, counts} <- validate_properties(schema, depth, counts),
         {:ok, counts} <- validate_items(schema, depth, counts),
         {:ok, counts} <- validate_additional_properties(schema, depth, counts),
         {:ok, counts} <- validate_enum(schema, counts),
         {:ok, counts} <- validate_combinators(schema, depth, counts) do
      {:ok, counts}
    end
  end

  defp validate_schema(_schema, _depth, _counts), do: invalid(:schema_too_deep)

  defp string_keys(schema) do
    if Enum.all?(Map.keys(schema), &is_binary/1), do: :ok, else: invalid(:non_string_schema_key)
  end

  defp supported_keywords(schema) do
    case Enum.find(Map.keys(schema), &(not MapSet.member?(@keywords, &1))) do
      nil -> :ok
      _keyword -> invalid(:unsupported_schema_keyword)
    end
  end

  defp validate_type(%{"type" => type}) when type in @types, do: :ok

  defp validate_type(%{"type" => types}) when is_list(types) do
    if types != [] and Enum.all?(types, &(&1 in @types)) and length(types) == length(Enum.uniq(types)),
      do: :ok,
      else: invalid(:invalid_schema_type)
  end

  defp validate_type(schema), do: if(Map.has_key?(schema, "type"), do: invalid(:invalid_schema_type), else: :ok)

  defp validate_required(%{"required" => required, "properties" => properties})
       when is_list(required) and is_map(properties) do
    property_names = Map.keys(properties)

    if Enum.all?(required, &is_binary/1) and length(required) == length(Enum.uniq(required)) and
         Enum.all?(required, &(&1 in property_names)) do
      :ok
    else
      invalid(:invalid_required_properties)
    end
  end

  defp validate_required(%{"required" => _required}), do: invalid(:invalid_required_properties)
  defp validate_required(_schema), do: :ok

  defp validate_scalar_limits(schema) do
    checks = [
      {"minLength", &non_negative_integer?/1},
      {"maxLength", &non_negative_integer?/1},
      {"minimum", &is_number/1},
      {"maximum", &is_number/1},
      {"minItems", &non_negative_integer?/1},
      {"maxItems", &non_negative_integer?/1}
    ]

    if Enum.all?(checks, fn {key, valid?} -> not Map.has_key?(schema, key) or valid?.(schema[key]) end),
      do: validate_limit_order(schema),
      else: invalid(:invalid_schema_limit)
  end

  defp validate_limit_order(schema) do
    pairs = [{"minLength", "maxLength"}, {"minimum", "maximum"}, {"minItems", "maxItems"}]

    if Enum.all?(pairs, fn {minimum, maximum} ->
         not (Map.has_key?(schema, minimum) and Map.has_key?(schema, maximum)) or schema[minimum] <= schema[maximum]
       end),
       do: :ok,
       else: invalid(:invalid_schema_limit)
  end

  defp validate_properties(%{"properties" => properties}, depth, counts) when is_map(properties) do
    count = counts.properties + map_size(properties)

    with :ok <- within(count, @maximum_properties, :too_many_schema_properties) do
      Enum.reduce_while(properties, {:ok, %{counts | properties: count}}, fn
        {name, child}, {:ok, acc} when is_binary(name) and is_map(child) ->
          case validate_schema(child, depth + 1, acc) do
            {:ok, next} -> {:cont, {:ok, next}}
            error -> {:halt, error}
          end

        _entry, _acc ->
          {:halt, invalid(:invalid_schema_properties)}
      end)
    end
  end

  defp validate_properties(%{"properties" => _properties}, _depth, _counts),
    do: invalid(:invalid_schema_properties)

  defp validate_properties(_schema, _depth, counts), do: {:ok, counts}

  defp validate_items(%{"items" => child}, depth, counts) when is_map(child),
    do: validate_schema(child, depth + 1, counts)

  defp validate_items(%{"items" => _child}, _depth, _counts), do: invalid(:invalid_schema_items)
  defp validate_items(_schema, _depth, counts), do: {:ok, counts}

  defp validate_additional_properties(%{"additionalProperties" => value}, _depth, counts)
       when is_boolean(value),
       do: {:ok, counts}

  defp validate_additional_properties(%{"additionalProperties" => child}, depth, counts) when is_map(child),
    do: validate_schema(child, depth + 1, counts)

  defp validate_additional_properties(%{"additionalProperties" => _value}, _depth, _counts),
    do: invalid(:invalid_additional_properties)

  defp validate_additional_properties(_schema, _depth, counts), do: {:ok, counts}

  defp validate_enum(%{"enum" => values}, counts) when is_list(values) and values != [] do
    count = counts.enums + length(values)

    with :ok <- within(count, @maximum_enum_values, :too_many_schema_enum_values),
         {:ok, _encoded} <- Jason.encode(values) do
      {:ok, %{counts | enums: count}}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> invalid(:invalid_schema_enum)
    end
  end

  defp validate_enum(%{"enum" => _values}, _counts), do: invalid(:invalid_schema_enum)
  defp validate_enum(_schema, counts), do: {:ok, counts}

  defp validate_combinators(schema, depth, counts) do
    Enum.reduce_while(~w(anyOf oneOf allOf), {:ok, counts}, fn keyword, {:ok, acc} ->
      case Map.fetch(schema, keyword) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, branches} when is_list(branches) and branches != [] ->
          count = acc.combinators + length(branches)

          case within(count, @maximum_combinators, :too_many_schema_combinators) do
            :ok ->
              result =
                Enum.reduce_while(branches, {:ok, %{acc | combinators: count}}, fn
                  branch, {:ok, branch_counts} when is_map(branch) ->
                    case validate_schema(branch, depth + 1, branch_counts) do
                      {:ok, next} -> {:cont, {:ok, next}}
                      error -> {:halt, error}
                    end

                  _branch, _state ->
                    {:halt, invalid(:invalid_schema_combinator)}
                end)

              case result do
                {:ok, next} -> {:cont, {:ok, next}}
                error -> {:halt, error}
              end

            error ->
              {:halt, error}
          end

        {:ok, _branches} ->
          {:halt, invalid(:invalid_schema_combinator)}
      end
    end)
  end

  defp canonical(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, canonical(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value

  defp validate_value(value, schema) do
    with :ok <- validate_value_type(value, schema["type"]),
         :ok <- validate_value_enum(value, schema),
         :ok <- validate_value_const(value, schema),
         :ok <- validate_string(value, schema),
         :ok <- validate_number(value, schema),
         :ok <- validate_array(value, schema),
         :ok <- validate_object(value, schema),
         :ok <- validate_value_combinators(value, schema) do
      :ok
    end
  end

  defp validate_value_type(_value, nil), do: :ok

  defp validate_value_type(value, types) when is_list(types),
    do: if(Enum.any?(types, &type?(&1, value)), do: :ok, else: :error)

  defp validate_value_type(value, type), do: if(type?(type, value), do: :ok, else: :error)

  defp type?("null", value), do: is_nil(value)
  defp type?("boolean", value), do: is_boolean(value)
  defp type?("object", value), do: is_map(value)
  defp type?("array", value), do: is_list(value)
  defp type?("number", value), do: is_number(value)
  defp type?("integer", value), do: is_integer(value)
  defp type?("string", value), do: is_binary(value)
  defp type?(_type, _value), do: false

  defp validate_value_enum(value, %{"enum" => values}), do: if(value in values, do: :ok, else: :error)
  defp validate_value_enum(_value, _schema), do: :ok
  defp validate_value_const(value, %{"const" => expected}), do: if(value == expected, do: :ok, else: :error)
  defp validate_value_const(_value, _schema), do: :ok

  defp validate_string(value, schema) when is_binary(value) do
    length = String.length(value)

    if (not Map.has_key?(schema, "minLength") or length >= schema["minLength"]) and
         (not Map.has_key?(schema, "maxLength") or length <= schema["maxLength"]),
       do: :ok,
       else: :error
  end

  defp validate_string(_value, _schema), do: :ok

  defp validate_number(value, schema) when is_number(value) do
    if (not Map.has_key?(schema, "minimum") or value >= schema["minimum"]) and
         (not Map.has_key?(schema, "maximum") or value <= schema["maximum"]),
       do: :ok,
       else: :error
  end

  defp validate_number(_value, _schema), do: :ok

  defp validate_array(value, schema) when is_list(value) do
    valid_length =
      (not Map.has_key?(schema, "minItems") or length(value) >= schema["minItems"]) and
        (not Map.has_key?(schema, "maxItems") or length(value) <= schema["maxItems"])

    valid_items =
      case schema["items"] do
        nil -> true
        item_schema -> Enum.all?(value, &(validate_value(&1, item_schema) == :ok))
      end

    if valid_length and valid_items, do: :ok, else: :error
  end

  defp validate_array(_value, _schema), do: :ok

  defp validate_object(value, schema) when is_map(value) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])
    additional = Map.get(schema, "additionalProperties", true)

    required? = Enum.all?(required, &Map.has_key?(value, &1))

    properties? =
      Enum.all?(value, fn {key, child} ->
        case Map.fetch(properties, key) do
          {:ok, child_schema} -> validate_value(child, child_schema) == :ok
          :error when additional == true -> true
          :error when additional == false -> false
          :error when is_map(additional) -> validate_value(child, additional) == :ok
        end
      end)

    if required? and properties?, do: :ok, else: :error
  end

  defp validate_object(_value, _schema), do: :ok

  defp validate_value_combinators(value, schema) do
    checks = [
      {"allOf", fn matches -> matches == length(schema["allOf"]) end},
      {"anyOf", fn matches -> matches >= 1 end},
      {"oneOf", fn matches -> matches == 1 end}
    ]

    if Enum.all?(checks, fn {keyword, accepted?} ->
         case schema[keyword] do
           nil -> true
           branches -> branches |> Enum.count(&(validate_value(value, &1) == :ok)) |> accepted?.()
         end
       end),
       do: :ok,
       else: :error
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp within(value, maximum, _kind) when value <= maximum, do: :ok
  defp within(_value, _maximum, kind), do: invalid(kind)

  defp invalid(kind),
    do:
      {:error,
       Error.validation("structured-output schema is not supported",
         details: %{failure_kind: kind, field: :structured_output}
       )}
end
