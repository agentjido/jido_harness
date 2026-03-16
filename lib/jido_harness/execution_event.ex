defmodule Jido.Harness.ExecutionEvent do
  @moduledoc """
  Versioned runtime event emitted through the Session Control IR.
  """

  alias Jido.Harness.SessionControl

  @schema Zoi.struct(
            __MODULE__,
            %{
              schema_version: Zoi.string() |> Zoi.default(SessionControl.version()),
              event_id: Zoi.string(),
              type: Zoi.atom(),
              session_id: Zoi.string(),
              run_id: Zoi.string(),
              runtime_id: Zoi.atom(),
              provider: Zoi.atom() |> Zoi.nullish(),
              sequence: Zoi.integer() |> Zoi.nullish(),
              timestamp: Zoi.string(),
              status: Zoi.atom() |> Zoi.nullish(),
              payload: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.default(%{}),
              raw: Zoi.any() |> Zoi.nullish(),
              metadata: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for execution events."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds an execution event from validated attributes."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs), do: Zoi.parse(@schema, attrs)

  @doc "Builds an execution event or raises on validation failure."
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "Invalid #{inspect(__MODULE__)}: #{inspect(reason)}"
    end
  end
end
