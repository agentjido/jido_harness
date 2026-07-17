defmodule Jido.Harness.SessionRequest do
  @moduledoc "Validated provider-neutral configuration for an interactive session."

  @approval_modes [:default, :prompt, :auto_edit, :auto_approve]
  @sandbox_modes [:default, :read_only, :workspace_write, :unrestricted]
  @reasoning_efforts [:low, :medium, :high]
  @keys [
    :provider,
    :cwd,
    :model,
    :provider_session_id,
    :system_prompt,
    :allowed_tools,
    :disallowed_tools,
    :add_dirs,
    :mcp_config,
    :approval_mode,
    :sandbox_mode,
    :reasoning_effort,
    :env,
    :metadata,
    :provider_options,
    :transport,
    :turn_runtime_timeout_ms,
    :turn_idle_timeout_ms,
    :session_idle_timeout_ms,
    :approval_timeout_ms,
    :retention
  ]

  @schema Zoi.struct(
            __MODULE__,
            %{
              provider: Zoi.atom() |> Zoi.nullish(),
              cwd: Zoi.string(),
              model: Zoi.string() |> Zoi.nullish(),
              provider_session_id: Zoi.string() |> Zoi.nullish(),
              system_prompt: Zoi.string() |> Zoi.nullish(),
              allowed_tools: Zoi.array(Zoi.string()) |> Zoi.nullish(),
              disallowed_tools: Zoi.array(Zoi.string()) |> Zoi.nullish(),
              add_dirs: Zoi.array(Zoi.string()) |> Zoi.nullish(),
              mcp_config: Zoi.any() |> Zoi.nullish(),
              approval_mode: Zoi.enum(@approval_modes) |> Zoi.default(:default),
              sandbox_mode: Zoi.enum(@sandbox_modes) |> Zoi.default(:default),
              reasoning_effort: Zoi.enum(@reasoning_efforts) |> Zoi.nullish(),
              env: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.default(%{}),
              metadata: Zoi.map(Zoi.union([Zoi.string(), Zoi.atom()]), Zoi.any()) |> Zoi.default(%{}),
              provider_options: Zoi.map(Zoi.union([Zoi.string(), Zoi.atom()]), Zoi.any()) |> Zoi.default(%{}),
              transport: Zoi.atom() |> Zoi.nullish(),
              turn_runtime_timeout_ms: Zoi.union([Zoi.integer(), Zoi.literal(:infinity)]) |> Zoi.default(:infinity),
              turn_idle_timeout_ms: Zoi.union([Zoi.integer(), Zoi.literal(:infinity)]) |> Zoi.default(:infinity),
              session_idle_timeout_ms: Zoi.union([Zoi.integer(), Zoi.literal(:infinity)]) |> Zoi.default(:infinity),
              approval_timeout_ms: Zoi.union([Zoi.integer(), Zoi.literal(:infinity)]) |> Zoi.default(:infinity),
              retention: Zoi.map(Zoi.union([Zoi.string(), Zoi.atom()]), Zoi.any()) |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @key_strings Map.new(@keys, &{Atom.to_string(&1), &1})

  @doc "Returns the validation schema for session requests."
  def schema, do: @schema

  @doc "Validates an interactive session request."
  def new(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_keys(attrs),
         :ok <- validate_values(attrs),
         {:ok, retention} <- Jido.Harness.RetentionOptions.normalize(Map.get(attrs, :retention, %{})),
         attrs = Map.put(attrs, :retention, retention),
         {:ok, request} <- parse(Map.put_new(attrs, :cwd, File.cwd!())),
         true <- File.dir?(request.cwd) do
      {:ok, request}
    else
      false -> {:error, Jido.Harness.Error.validation("cwd must be an existing directory")}
      {:error, _reason} = error -> error
    end
  end

  def new(attrs) when is_list(attrs) do
    if Enum.all?(attrs, &match?({_, _}, &1)),
      do: new(Map.new(attrs)),
      else: {:error, Jido.Harness.Error.validation("session request must be a map")}
  end

  def new(other),
    do: {:error, Jido.Harness.Error.validation("session request must be a map", details: %{value: inspect(other)})}

  def new!(attrs) do
    case new(attrs) do
      {:ok, request} -> request
      {:error, error} -> raise error
    end
  end

  defp normalize_keys(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when key in @keys ->
        {:cont, {:ok, Map.put(acc, key, value)}}

      {key, value}, {:ok, acc} when is_binary(key) ->
        case Map.fetch(@key_strings, key) do
          {:ok, atom} -> {:cont, {:ok, Map.put(acc, atom, value)}}
          :error -> {:halt, unknown_key(key)}
        end

      {key, _value}, _acc ->
        {:halt, unknown_key(key)}
    end)
  end

  defp validate_values(attrs) do
    timeout_fields = [
      :turn_runtime_timeout_ms,
      :turn_idle_timeout_ms,
      :session_idle_timeout_ms,
      :approval_timeout_ms
    ]

    cond do
      field = Enum.find(timeout_fields, &invalid_timeout?(Map.get(attrs, &1, :infinity))) ->
        {:error, Jido.Harness.Error.validation("#{field} must be :infinity or a positive integer")}

      not is_map(Map.get(attrs, :provider_options, %{})) ->
        {:error, Jido.Harness.Error.validation("provider_options must be a map")}

      not is_map(Map.get(attrs, :retention, %{})) ->
        {:error, Jido.Harness.Error.validation("retention must be a map")}

      shadow = Enum.find(Map.keys(Map.get(attrs, :provider_options, %{})), &shadows_normalized?/1) ->
        {:error,
         Jido.Harness.Error.validation("provider_options cannot shadow normalized fields", details: %{key: shadow})}

      true ->
        :ok
    end
  end

  defp parse(attrs) do
    case Zoi.parse(@schema, attrs) do
      {:ok, request} ->
        {:ok, request}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid session request", details: %{reason: inspect(reason)})}
    end
  end

  defp invalid_timeout?(:infinity), do: false
  defp invalid_timeout?(value), do: not (is_integer(value) and value > 0)
  defp shadows_normalized?(key) when is_atom(key), do: key in @keys
  defp shadows_normalized?(key) when is_binary(key), do: Map.has_key?(@key_strings, key)
  defp shadows_normalized?(_key), do: false

  defp unknown_key(key),
    do: {:error, Jido.Harness.Error.validation("unknown session request option", details: %{key: key})}
end
