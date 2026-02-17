defmodule Jido.Harness.Event do
  @moduledoc """
  Normalized event struct emitted by CLI agent adapters.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              type: Zoi.atom(),
              provider: Zoi.atom(),
              session_id: Zoi.string() |> Zoi.nullish(),
              timestamp: Zoi.string() |> Zoi.nullish(),
              payload: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.default(%{}),
              raw: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for this struct."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a new Event from a map, validating with Zoi."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs), do: Zoi.parse(@schema, attrs)

  @doc "Like new/1 but raises on validation errors."
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "Invalid #{inspect(__MODULE__)}: #{inspect(reason)}"
    end
  end
end
