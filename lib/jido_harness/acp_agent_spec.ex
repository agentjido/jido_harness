defmodule Jido.Harness.ACPAgentSpec do
  @moduledoc "Launch and capability description for one ACP coding agent."

  alias Jido.Harness.SessionCapabilities

  @options Zoi.union([Zoi.array(Zoi.atom()), Zoi.literal(:adapter)])

  @schema Zoi.struct(
            __MODULE__,
            %{
              executable: Zoi.string(),
              argv: Zoi.array(Zoi.string()) |> Zoi.default([]),
              source: Zoi.enum([:native, :adapter]),
              package: Zoi.string() |> Zoi.nullish(),
              maturity: Zoi.enum([:stable, :experimental]) |> Zoi.default(:stable),
              env: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.default(%{}),
              capabilities: SessionCapabilities.schema() |> Zoi.default(%SessionCapabilities{}),
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

  @doc "Returns the validation schema for ACP agent metadata."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates and constructs ACP agent metadata."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    case Zoi.parse(@schema, Map.new(attrs)) do
      {:ok, spec} ->
        validate(spec)

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid ACP agent specification", details: %{reason: inspect(reason)})}
    end
  end

  defp validate(%__MODULE__{source: :adapter, package: package} = spec) do
    if exact_package?(package) do
      validate_options(spec)
    else
      {:error, Jido.Harness.Error.validation("ACP adapter source requires an exact package")}
    end
  end

  defp validate(%__MODULE__{source: :native, package: nil} = spec), do: validate_options(spec)

  defp validate(%__MODULE__{source: :native}) do
    {:error, Jido.Harness.Error.validation("native ACP source cannot declare an adapter package")}
  end

  defp validate_options(spec) do
    fields = [
      session_options: spec.session_options,
      session_provider_options: spec.session_provider_options,
      turn_options: spec.turn_options,
      turn_provider_options: spec.turn_provider_options,
      configuration_options: spec.configuration_options
    ]

    case Enum.find(fields, fn {_field, options} -> is_list(options) and options != Enum.uniq(options) end) do
      nil ->
        {:ok, spec}

      {field, _options} ->
        {:error, Jido.Harness.Error.validation("ACP option names must be unique", details: %{field: field})}
    end
  end

  defp exact_package?(package) when is_binary(package), do: Regex.match?(~r/@[^@\/]+$/, package)
  defp exact_package?(_package), do: false

  @doc "Validates and constructs ACP agent metadata, raising on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, spec} -> spec
      {:error, error} -> raise error
    end
  end

  @doc "Builds a native ACP agent specification with the common Harness baseline."
  @spec native(String.t(), [String.t()], map() | keyword()) :: t()
  def native(executable, argv, overrides \\ %{}) do
    baseline(executable, argv, :native, overrides)
  end

  @doc "Builds an ACP adapter specification with the common Harness baseline."
  @spec adapter(String.t(), String.t(), map() | keyword()) :: t()
  def adapter(executable, package, overrides \\ %{}) do
    overrides = overrides |> Map.new() |> Map.put(:package, package)
    baseline(executable, [], :adapter, overrides)
  end

  defp baseline(executable, argv, source, overrides) do
    common = %{
      executable: executable,
      argv: argv,
      source: source,
      capabilities: %SessionCapabilities{},
      session_options: [:provider_session_id, :mcp_config],
      turn_options: []
    }

    common
    |> Map.merge(Map.new(overrides))
    |> new!()
  end
end
