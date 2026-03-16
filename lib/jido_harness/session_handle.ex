defmodule Jido.Harness.SessionHandle do
  @moduledoc """
  Opaque runtime session handle exposed through the Session Control IR.
  """

  alias Jido.Harness.SessionControl

  @schema Zoi.struct(
            __MODULE__,
            %{
              schema_version: Zoi.string() |> Zoi.default(SessionControl.version()),
              session_id: Zoi.string(),
              runtime_id: Zoi.atom(),
              provider: Zoi.atom() |> Zoi.nullish(),
              status: Zoi.atom() |> Zoi.default(:ready),
              driver_ref: Zoi.any() |> Zoi.nullish(),
              metadata: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for session handles."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a session handle from validated attributes."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs), do: Zoi.parse(@schema, attrs)

  @doc "Builds a session handle or raises on validation failure."
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "Invalid #{inspect(__MODULE__)}: #{inspect(reason)}"
    end
  end
end
