defmodule Jido.Harness.InteractionCapabilities do
  @moduledoc "Granular capabilities for an interactive provider transport."

  @modes [:native, :managed, :process, false]
  @support Zoi.union([Zoi.enum([:native, :managed, :process]), Zoi.literal(false)])

  @schema Zoi.struct(
            __MODULE__,
            %{
              transport: Zoi.atom(),
              maturity: Zoi.enum([:stable, :experimental]) |> Zoi.default(:stable),
              process: Zoi.enum([:persistent, :per_turn]) |> Zoi.default(:per_turn),
              multi_turn: @support |> Zoi.default(false),
              follow_up: @support |> Zoi.default(false),
              steer: @support |> Zoi.default(false),
              interrupt: @support |> Zoi.default(false),
              approvals: @support |> Zoi.default(false),
              structured_output: @support |> Zoi.default(false),
              multimodal: @support |> Zoi.default(false),
              dynamic_model: @support |> Zoi.default(false),
              dynamic_configuration: @support |> Zoi.default(false)
            },
            coerce: true
          )

  @type support :: :native | :managed | :process | false
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the validation schema for interactive transport capabilities."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates and constructs interactive transport capabilities."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    case Zoi.parse(@schema, Map.new(attrs)) do
      {:ok, capabilities} ->
        {:ok, capabilities}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid interaction capabilities", details: %{reason: inspect(reason)})}
    end
  end

  @doc "Validates and constructs interaction capabilities, raising on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, capabilities} -> capabilities
      {:error, error} -> raise error
    end
  end

  @doc "Returns whether a capability is available in any normalized form."
  @spec supported?(t(), atom()) :: boolean()
  def supported?(%__MODULE__{} = capabilities, name) do
    Map.get(capabilities, name, false) in (@modes -- [false])
  end
end
