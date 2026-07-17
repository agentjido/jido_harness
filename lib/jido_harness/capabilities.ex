defmodule Jido.Harness.Capabilities do
  @moduledoc "Normalized provider capabilities."

  @schema Zoi.struct(
            __MODULE__,
            %{
              streaming?: Zoi.boolean() |> Zoi.default(true),
              tool_calls?: Zoi.boolean() |> Zoi.default(false),
              tool_results?: Zoi.boolean() |> Zoi.default(false),
              thinking?: Zoi.boolean() |> Zoi.default(false),
              resume?: Zoi.boolean() |> Zoi.default(false),
              usage?: Zoi.boolean() |> Zoi.default(false),
              file_changes?: Zoi.boolean() |> Zoi.default(false),
              native_cancel?: Zoi.boolean() |> Zoi.default(false)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the validation schema for finite-run provider capabilities."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates and constructs finite-run provider capabilities."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    case Zoi.parse(@schema, Map.new(attrs)) do
      {:ok, capabilities} ->
        {:ok, capabilities}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid adapter capabilities", details: %{reason: inspect(reason)})}
    end
  end

  @doc "Validates and constructs capabilities, raising on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, capabilities} -> capabilities
      {:error, error} -> raise error
    end
  end
end
