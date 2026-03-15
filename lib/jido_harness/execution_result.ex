defmodule Jido.Harness.ExecutionResult do
  @moduledoc """
  Final run projection normalized through the Session Control IR.
  """

  alias Jido.Harness.SessionControl

  @schema Zoi.struct(
            __MODULE__,
            %{
              schema_version: Zoi.string() |> Zoi.default(SessionControl.version()),
              run_id: Zoi.string(),
              session_id: Zoi.string(),
              runtime_id: Zoi.atom(),
              provider: Zoi.atom() |> Zoi.nullish(),
              status: Zoi.atom(),
              text: Zoi.string() |> Zoi.nullish(),
              messages: Zoi.array(Zoi.any()) |> Zoi.default([]),
              cost: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.default(%{}),
              error: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.nullish(),
              duration_ms: Zoi.integer() |> Zoi.nullish(),
              stop_reason: Zoi.string() |> Zoi.nullish(),
              metadata: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.default(%{})
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
