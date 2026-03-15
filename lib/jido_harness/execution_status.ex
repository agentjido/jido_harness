defmodule Jido.Harness.ExecutionStatus do
  @moduledoc """
  Status projection for runtime session or run lifecycle checks.
  """

  alias Jido.Harness.SessionControl

  @schema Zoi.struct(
            __MODULE__,
            %{
              schema_version: Zoi.string() |> Zoi.default(SessionControl.version()),
              runtime_id: Zoi.atom(),
              session_id: Zoi.string() |> Zoi.nullish(),
              run_id: Zoi.string() |> Zoi.nullish(),
              scope: Zoi.atom(),
              state: Zoi.atom(),
              timestamp: Zoi.string() |> Zoi.nullish(),
              message: Zoi.string() |> Zoi.nullish(),
              details: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs), do: Zoi.parse(@schema, attrs)

  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "Invalid #{inspect(__MODULE__)}: #{inspect(reason)}"
    end
  end
end
