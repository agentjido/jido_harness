defmodule Jido.Harness.RunResult do
  @moduledoc """
  Normalized terminal response from one finite harness run.

  `status` is `:completed`, `:failed`, or `:cancelled`. `text` is a bounded
  output tail; when `text_truncated?` is true, cursor replay is the source for
  the complete retained event sequence. Optional usage depends on provider
  capability.
  """

  alias Jido.Harness.{Error, Event}

  @schema Zoi.struct(
            __MODULE__,
            %{
              run_id: Zoi.string(),
              provider: Zoi.atom(),
              provider_session_id: Zoi.string() |> Zoi.nullish(),
              status: Zoi.enum([:completed, :failed, :cancelled]),
              text: Zoi.string() |> Zoi.default(""),
              text_truncated?: Zoi.boolean() |> Zoi.default(false),
              usage: Zoi.map() |> Zoi.default(%{}),
              events: Zoi.array(Event.schema()) |> Zoi.default([]),
              metadata: Zoi.map() |> Zoi.default(%{}),
              error: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the validation schema for terminal run results."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates and constructs a terminal run result."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    case Zoi.parse(@schema, Map.new(attrs)) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, Error.validation("invalid run result", details: %{reason: inspect(reason)})}
    end
  end

  @doc "Validates and constructs a run result, raising on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
