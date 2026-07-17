defmodule Jido.Harness.ApprovalResponse do
  @moduledoc "Validated response to an interactive provider approval request."

  @schema Zoi.struct(
            __MODULE__,
            %{
              decision: Zoi.enum([:approve, :deny]),
              scope: Zoi.enum([:once, :session]) |> Zoi.default(:once),
              reason: Zoi.string() |> Zoi.nullish(),
              provider_options: Zoi.map(Zoi.union([Zoi.string(), Zoi.atom()]), Zoi.any()) |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the validation schema for approval responses."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates an approval decision or response map."
  @spec new(:approve | :deny | map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(decision) when decision in [:approve, :deny], do: new(%{decision: decision})

  def new(attrs) when is_map(attrs) or is_list(attrs) do
    case Zoi.parse(@schema, Map.new(attrs)) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid approval response", details: %{reason: inspect(reason)})}
    end
  end

  def new(other),
    do:
      {:error,
       Jido.Harness.Error.validation("approval response must be :approve, :deny, or a map",
         details: %{value: inspect(other)}
       )}

  @doc "Validates an approval response and raises on invalid input."
  @spec new!(:approve | :deny | map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end
end
