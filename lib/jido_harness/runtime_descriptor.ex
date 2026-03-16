defmodule Jido.Harness.RuntimeDescriptor do
  @moduledoc """
  Provider-aware capability descriptor for a runtime driver.
  """

  alias Jido.Harness.SessionControl

  @schema Zoi.struct(
            __MODULE__,
            %{
              schema_version: Zoi.string() |> Zoi.default(SessionControl.version()),
              runtime_id: Zoi.atom(),
              provider: Zoi.atom() |> Zoi.nullish(),
              label: Zoi.string(),
              session_mode: Zoi.atom(),
              streaming?: Zoi.boolean() |> Zoi.default(true),
              cancellation?: Zoi.boolean() |> Zoi.default(false),
              approvals?: Zoi.boolean() |> Zoi.default(false),
              cost?: Zoi.boolean() |> Zoi.default(false),
              subscribe?: Zoi.boolean() |> Zoi.default(false),
              resume?: Zoi.boolean() |> Zoi.default(false),
              metadata: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for runtime descriptors."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a runtime descriptor from validated attributes."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs), do: Zoi.parse(@schema, attrs)

  @doc "Builds a runtime descriptor or raises on validation failure."
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "Invalid #{inspect(__MODULE__)}: #{inspect(reason)}"
    end
  end
end
