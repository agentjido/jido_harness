defmodule Jido.Harness.RunRequest do
  @moduledoc """
  Validated request struct for running a CLI coding agent.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              prompt: Zoi.string(),
              cwd: Zoi.string() |> Zoi.nullish(),
              model: Zoi.string() |> Zoi.nullish(),
              max_turns: Zoi.integer() |> Zoi.nullish(),
              timeout_ms: Zoi.integer() |> Zoi.nullish(),
              system_prompt: Zoi.string() |> Zoi.nullish(),
              allowed_tools: Zoi.array(Zoi.string()) |> Zoi.nullish(),
              attachments: Zoi.array(Zoi.string()) |> Zoi.default([]),
              metadata: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for this struct."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a new RunRequest from a map, validating with Zoi."
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
