defmodule Jido.Harness.SessionTransportSpec do
  @moduledoc "Static description of an adapter's interactive transport."

  alias Jido.Harness.InteractionCapabilities

  @options Zoi.union([Zoi.array(Zoi.atom()), Zoi.literal(:adapter)])
  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.atom(),
              adapter: Zoi.module(),
              minimum_version: Zoi.string() |> Zoi.nullish(),
              capabilities: InteractionCapabilities.schema(),
              session_options: @options |> Zoi.default([]),
              session_provider_options: @options |> Zoi.default([]),
              turn_options: @options |> Zoi.default([]),
              turn_provider_options: @options |> Zoi.default([]),
              configuration_options: Zoi.array(Zoi.atom()) |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the schema for interactive transport metadata."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates and constructs interactive transport metadata."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    case Zoi.parse(@schema, Map.new(attrs)) do
      {:ok, spec} ->
        {:ok, spec}

      {:error, reason} ->
        {:error,
         Jido.Harness.Error.validation("invalid session transport specification",
           details: %{reason: inspect(reason)}
         )}
    end
  end

  @doc "Validates and constructs transport metadata, raising on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, spec} -> spec
      {:error, error} -> raise error
    end
  end

  @doc false
  def managed(name \\ :managed, overrides \\ %{}) do
    capabilities =
      InteractionCapabilities.new!(
        Map.merge(
          %{
            transport: name,
            process: :per_turn,
            multi_turn: :managed,
            follow_up: :managed,
            interrupt: :process,
            dynamic_model: :managed,
            dynamic_configuration: :managed
          },
          Map.new(overrides)
        )
      )

    %__MODULE__{
      name: name,
      adapter: Jido.Harness.SessionAdapters.Managed,
      capabilities: capabilities,
      session_options: :adapter,
      session_provider_options: :adapter,
      turn_options: :adapter,
      turn_provider_options: :adapter,
      configuration_options: [:model, :reasoning_effort, :approval_mode, :sandbox_mode]
    }
  end
end
