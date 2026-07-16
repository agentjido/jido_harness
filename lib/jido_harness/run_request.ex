defmodule Jido.Harness.RunRequest do
  @moduledoc "Validated, provider-neutral request for a harness run."

  @approval_modes [:default, :prompt, :auto_edit, :auto_approve]
  @sandbox_modes [:default, :read_only, :workspace_write, :unrestricted]
  @reasoning_efforts [:low, :medium, :high]
  @keys [
    :prompt,
    :provider,
    :cwd,
    :model,
    :session_id,
    :max_turns,
    :runtime_timeout_ms,
    :idle_timeout_ms,
    :system_prompt,
    :allowed_tools,
    :disallowed_tools,
    :add_dirs,
    :mcp_config,
    :approval_mode,
    :sandbox_mode,
    :attachments,
    :reasoning_effort,
    :env,
    :metadata,
    :provider_options
  ]

  @schema Zoi.struct(
            __MODULE__,
            %{
              prompt: Zoi.string(),
              provider: Zoi.atom() |> Zoi.nullish(),
              cwd: Zoi.string(),
              model: Zoi.string() |> Zoi.nullish(),
              session_id: Zoi.string() |> Zoi.nullish(),
              max_turns: Zoi.integer() |> Zoi.nullish(),
              runtime_timeout_ms: Zoi.union([Zoi.integer(), Zoi.literal(:infinity)]) |> Zoi.default(:infinity),
              idle_timeout_ms: Zoi.union([Zoi.integer(), Zoi.literal(:infinity)]) |> Zoi.default(:infinity),
              system_prompt: Zoi.string() |> Zoi.nullish(),
              allowed_tools: Zoi.array(Zoi.string()) |> Zoi.nullish(),
              disallowed_tools: Zoi.array(Zoi.string()) |> Zoi.nullish(),
              add_dirs: Zoi.array(Zoi.string()) |> Zoi.nullish(),
              mcp_config: Zoi.any() |> Zoi.nullish(),
              approval_mode: Zoi.enum(@approval_modes) |> Zoi.default(:default),
              sandbox_mode: Zoi.enum(@sandbox_modes) |> Zoi.default(:default),
              attachments: Zoi.array(Zoi.string()) |> Zoi.default([]),
              reasoning_effort: Zoi.enum(@reasoning_efforts) |> Zoi.nullish(),
              env: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.default(%{}),
              metadata: Zoi.map(Zoi.union([Zoi.string(), Zoi.atom()]), Zoi.any()) |> Zoi.default(%{}),
              provider_options: Zoi.map(Zoi.union([Zoi.string(), Zoi.atom()]), Zoi.any()) |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @key_strings Map.new(@keys, &{Atom.to_string(&1), &1})

  @spec schema() :: Zoi.schema()
  @doc "Returns the Zoi schema for provider-neutral run requests."
  def schema, do: @schema

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  @doc "Validates a provider-neutral request and its working directory."
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, normalized} <- normalize_keys(Map.new(attrs)),
         :ok <- validate_values(normalized),
         {:ok, request} <- parse(Map.put_new(normalized, :cwd, File.cwd!())),
         :ok <- validate_cwd(request.cwd) do
      {:ok, request}
    end
  end

  def new(other),
    do:
      {:error,
       Jido.Harness.Error.validation("request must be a map or keyword list", details: %{value: inspect(other)})}

  @spec new!(map() | keyword()) :: t()
  @doc "Validates a request, raising a normalized error on invalid input."
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

  defp unknown_key(key), do: {:error, Jido.Harness.Error.validation("unknown run request option", details: %{key: key})}

  defp validate_values(attrs) do
    cond do
      Map.has_key?(attrs, :prompt) and (not is_binary(attrs.prompt) or String.trim(attrs.prompt) == "") ->
        {:error, Jido.Harness.Error.validation("prompt must be a non-empty string", details: %{field: :prompt})}

      invalid_timeout?(Map.get(attrs, :runtime_timeout_ms, :infinity)) ->
        {:error, Jido.Harness.Error.validation("runtime_timeout_ms must be :infinity or a positive integer")}

      invalid_timeout?(Map.get(attrs, :idle_timeout_ms, :infinity)) ->
        {:error, Jido.Harness.Error.validation("idle_timeout_ms must be :infinity or a positive integer")}

      invalid_max_turns?(Map.get(attrs, :max_turns)) ->
        {:error, Jido.Harness.Error.validation("max_turns must be a positive integer", details: %{field: :max_turns})}

      not is_map(Map.get(attrs, :provider_options, %{})) ->
        {:error, Jido.Harness.Error.validation("provider_options must be a map", details: %{field: :provider_options})}

      shadowed = Enum.find(Map.keys(Map.get(attrs, :provider_options, %{})), &provider_option_shadows?/1) ->
        {:error,
         Jido.Harness.Error.validation("provider_options cannot shadow normalized fields", details: %{key: shadowed})}

      true ->
        :ok
    end
  end

  defp invalid_timeout?(:infinity), do: false
  defp invalid_timeout?(value), do: not (is_integer(value) and value > 0)
  defp invalid_max_turns?(nil), do: false
  defp invalid_max_turns?(value), do: not (is_integer(value) and value > 0)

  defp provider_option_shadows?(key) when is_atom(key), do: key in @keys
  defp provider_option_shadows?(key) when is_binary(key), do: Map.has_key?(@key_strings, key)
  defp provider_option_shadows?(_key), do: false

  defp parse(attrs) do
    case Zoi.parse(@schema, attrs) do
      {:ok, request} ->
        {:ok, request}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid run request", details: %{reason: inspect(reason)})}
    end
  end

  defp validate_cwd(path) do
    if File.dir?(path) do
      :ok
    else
      {:error, Jido.Harness.Error.validation("cwd must be an existing directory", details: %{cwd: path})}
    end
  end
end
