defmodule Jido.Harness.ProviderStatus do
  @moduledoc "Readiness and authentication status for a provider."

  alias Jido.Harness.{Capabilities, SessionTransportSpec}

  @schema Zoi.struct(
            __MODULE__,
            %{
              provider: Zoi.atom(),
              installed: Zoi.boolean() |> Zoi.default(false),
              compatible: Zoi.boolean() |> Zoi.default(false),
              authenticated: Zoi.union([Zoi.boolean(), Zoi.literal(:unknown)]) |> Zoi.default(:unknown),
              smoke_ready: Zoi.boolean() |> Zoi.default(false),
              capabilities: Capabilities.schema() |> Zoi.default(%Capabilities{}),
              session_transports: Zoi.array(SessionTransportSpec.schema()) |> Zoi.default([]),
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
  @doc "Returns whether the provider is installed, compatible, and not known to be unauthenticated."
  def ready?(%__MODULE__{smoke_ready: ready}), do: ready

  @doc false
  def finalize(%__MODULE__{} = status) do
    ready = status.installed and status.compatible and status.authenticated != false
    %{status | smoke_ready: ready}
  end
end
