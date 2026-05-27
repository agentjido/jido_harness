defmodule Jido.Harness.RunRequest do
  @moduledoc """
  Validated request struct for running a CLI coding agent.

  ## Permission fields

  In addition to `allowed_tools`, the schema carries first-class permission
  inputs so callers MAY express persona-level deny rules, filesystem scopes,
  MCP server bundles, and permission modes without per-provider metadata
  hacks:

    * `disallowed_tools` — explicit deny list (counterpart to `allowed_tools`)
    * `add_dirs` — additional filesystem directories the agent MAY access
    * `mcp_config` — MCP server configuration (map for programmatic servers
      or path string for a JSON config file)
    * `permission_mode` — one of `:default`, `:plan`, `:accept_edits`,
      `:bypass_permissions` (or the equivalent string)

  All fields are optional. Adapters that recognise a field MUST forward it to
  the underlying provider; adapters that do not MAY silently ignore it.
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
              disallowed_tools: Zoi.array(Zoi.string()) |> Zoi.nullish(),
              add_dirs: Zoi.array(Zoi.string()) |> Zoi.nullish(),
              mcp_config: Zoi.any() |> Zoi.nullish(),
              permission_mode: Zoi.any() |> Zoi.nullish(),
              attachments: Zoi.array(Zoi.string()) |> Zoi.default([]),
              session_id: Zoi.string() |> Zoi.nullish(),
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
