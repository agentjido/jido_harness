defmodule Jido.Harness.SessionCapabilities do
  @moduledoc "Capabilities available through a provider's ACP agent."

  @schema Zoi.struct(
            __MODULE__,
            %{
              load_session: Zoi.boolean() |> Zoi.default(false),
              follow_up: Zoi.boolean() |> Zoi.default(true),
              steer: Zoi.boolean() |> Zoi.default(false),
              interrupt: Zoi.boolean() |> Zoi.default(true),
              approvals: Zoi.boolean() |> Zoi.default(true),
              structured_output: Zoi.boolean() |> Zoi.default(false),
              multimodal: Zoi.boolean() |> Zoi.default(false),
              dynamic_model: Zoi.boolean() |> Zoi.default(false),
              dynamic_configuration: Zoi.boolean() |> Zoi.default(false),
              mcp: Zoi.boolean() |> Zoi.default(true),
              usage: Zoi.boolean() |> Zoi.default(false)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the validation schema for ACP session capabilities."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates and constructs ACP session capabilities."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    case Zoi.parse(@schema, Map.new(attrs)) do
      {:ok, capabilities} ->
        {:ok, capabilities}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid session capabilities", details: %{reason: inspect(reason)})}
    end
  end

  @doc "Validates and constructs ACP session capabilities, raising on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, capabilities} -> capabilities
      {:error, error} -> raise error
    end
  end

  @doc "Returns whether an ACP session capability is available."
  @spec supported?(t(), atom()) :: boolean()
  def supported?(%__MODULE__{} = capabilities, name), do: Map.get(capabilities, name, false) == true
end
