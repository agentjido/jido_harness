defmodule Jido.Harness.RuntimeContract do
  @moduledoc """
  Runtime metadata published by provider adapters for orchestration layers.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              provider: Zoi.atom(),
              host_env_required_any: Zoi.array(Zoi.string()) |> Zoi.default([]),
              host_env_required_all: Zoi.array(Zoi.string()) |> Zoi.default([]),
              sprite_env_forward: Zoi.array(Zoi.string()) |> Zoi.default([]),
              sprite_env_injected: Zoi.map(Zoi.string(), Zoi.string()) |> Zoi.default(%{}),
              runtime_tools_required: Zoi.array(Zoi.string()) |> Zoi.default([]),
              compatibility_probes: Zoi.array(Zoi.map(Zoi.string(), Zoi.any())) |> Zoi.default([]),
              install_steps: Zoi.array(Zoi.map(Zoi.string(), Zoi.any())) |> Zoi.default([]),
              auth_bootstrap_steps: Zoi.array(Zoi.string()) |> Zoi.default([]),
              triage_command_template: Zoi.string() |> Zoi.nullish(),
              coding_command_template: Zoi.string() |> Zoi.nullish(),
              success_markers: Zoi.array(Zoi.map(Zoi.string(), Zoi.any())) |> Zoi.default([]),
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

  @doc "Builds a new RuntimeContract from a map, validating with Zoi."
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
