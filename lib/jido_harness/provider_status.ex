defmodule Jido.Harness.ProviderStatus do
  @moduledoc """
  Normalized installation, compatibility, authentication, and readiness status.

  Authentication may be `:unknown` when a CLI uses cached login that cannot be
  proven without a live request. `acp_agent` describes the provider's common
  interactive ACP entry point.
  """

  alias Jido.Harness.{ACPAgentSpec, Capabilities}

  @schema Zoi.struct(
            __MODULE__,
            %{
              provider: Zoi.atom(),
              installed: Zoi.boolean() |> Zoi.default(false),
              compatible: Zoi.boolean() |> Zoi.default(false),
              authenticated: Zoi.union([Zoi.boolean(), Zoi.literal(:unknown)]) |> Zoi.default(:unknown),
              smoke_ready: Zoi.boolean() |> Zoi.default(false),
              capabilities: Capabilities.schema() |> Zoi.default(%Capabilities{}),
              acp_agent: ACPAgentSpec.schema() |> Zoi.nullish(),
              session_ready: Zoi.boolean() |> Zoi.default(false),
              version: Zoi.string() |> Zoi.nullish(),
              executable: Zoi.string() |> Zoi.nullish(),
              error: Zoi.any() |> Zoi.nullish(),
              details: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the validation schema for provider readiness."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates and constructs provider readiness information."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    case Zoi.parse(@schema, Map.new(attrs)) do
      {:ok, status} ->
        {:ok, status}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid provider status", details: %{reason: inspect(reason)})}
    end
  end

  @doc "Validates and constructs provider readiness, raising on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, status} -> status
      {:error, error} -> raise error
    end
  end

  @spec ready?(t()) :: boolean()
  @doc "Returns whether both the provider CLI and its ACP agent are ready."
  def ready?(%__MODULE__{smoke_ready: smoke_ready, session_ready: session_ready}),
    do: smoke_ready and session_ready

  @doc false
  def finalize(%__MODULE__{} = status) do
    ready = status.installed and status.compatible and status.authenticated != false
    %{status | smoke_ready: ready}
  end
end
