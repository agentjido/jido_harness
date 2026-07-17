defmodule Jido.Harness.ProcessSpec do
  @moduledoc "A structured, shell-free specification for a managed OS process."

  @keys [
    :executable,
    :argv,
    :cwd,
    :env,
    :env_mode,
    :stdin,
    :pty,
    :startup_timeout_ms,
    :runtime_timeout_ms,
    :idle_timeout_ms,
    :metadata,
    :retention
  ]

  @timeout Zoi.union([Zoi.integer(), Zoi.literal(:infinity)])
  @schema Zoi.struct(
            __MODULE__,
            %{
              executable: Zoi.string(),
              argv: Zoi.array(Zoi.string()) |> Zoi.default([]),
              cwd: Zoi.string() |> Zoi.nullish(),
              env: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.default(%{}),
              env_mode: Zoi.enum([:overlay, :replace]) |> Zoi.default(:overlay),
              stdin: Zoi.boolean() |> Zoi.default(true),
              pty: Zoi.any() |> Zoi.default(false),
              startup_timeout_ms: Zoi.integer() |> Zoi.default(15_000),
              runtime_timeout_ms: @timeout |> Zoi.default(:infinity),
              idle_timeout_ms: @timeout |> Zoi.default(:infinity),
              metadata: Zoi.map() |> Zoi.default(%{}),
              retention: Zoi.map() |> Zoi.default(%{}),
              lifecycle_owner: Zoi.pid() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the validation schema for shell-free process specifications."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  @doc "Validates and constructs a shell-free process specification."
  def new(%__MODULE__{} = spec), do: validate(spec)

  def new(attrs) when is_map(attrs) do
    case Enum.find(Map.keys(attrs), &(&1 not in @keys)) do
      nil ->
        attrs = Map.put_new(attrs, :cwd, File.cwd!())

        case Zoi.parse(@schema, attrs) do
          {:ok, spec} ->
            validate(spec)

          {:error, reason} ->
            {:error,
             Jido.Harness.Error.validation("invalid process specification", details: %{reason: inspect(reason)})}
        end

      key ->
        {:error, Jido.Harness.Error.validation("unknown process option", details: %{key: key})}
    end
  end

  def new(attrs) when is_list(attrs) do
    if Enum.all?(attrs, &match?({_, _}, &1)),
      do: new(Map.new(attrs)),
      else: {:error, Jido.Harness.Error.validation("process specification must be a map")}
  end

  def new(other),
    do:
      {:error, Jido.Harness.Error.validation("process specification must be a map", details: %{value: inspect(other)})}

  @spec new!(map() | keyword() | t()) :: t()
  @doc "Validates and constructs a process specification, raising on invalid input."
  def new!(attrs) do
    case new(attrs) do
      {:ok, spec} -> spec
      {:error, error} -> raise error
    end
  end

  @spec resolve_executable(String.t()) :: {:ok, String.t()} | {:error, Jido.Harness.Error.t()}
  @doc "Resolves an executable path without invoking a shell."
  def resolve_executable(executable) when is_binary(executable) do
    resolved =
      if String.contains?(executable, ["/", "\\"]) do
        Path.expand(executable)
      else
        System.find_executable(executable)
      end

    if is_binary(resolved) and File.exists?(resolved) do
      {:ok, resolved}
    else
      {:error, Jido.Harness.Error.new(:process, "executable not found", details: %{executable: executable})}
    end
  end

  defp validate(%__MODULE__{} = spec) do
    cond do
      not is_binary(spec.executable) or String.trim(spec.executable) == "" ->
        invalid("executable must be a non-empty string")

      not (is_list(spec.argv) and Enum.all?(spec.argv, &is_binary/1)) ->
        invalid("argv must be a list of strings")

      not is_binary(spec.cwd) or not File.dir?(spec.cwd) ->
        invalid("cwd must be an existing directory", %{cwd: spec.cwd})

      not is_map(spec.env) or not Enum.all?(spec.env, &valid_env?/1) ->
        invalid("env must use string names and string, false, or nil values")

      spec.env_mode not in [:overlay, :replace] ->
        invalid("env_mode must be :overlay or :replace")

      not is_boolean(spec.stdin) ->
        invalid("stdin must be a boolean")

      not (is_boolean(spec.pty) or Keyword.keyword?(spec.pty)) ->
        invalid("pty must be a boolean or keyword list")

      invalid_timeout?(spec.startup_timeout_ms) ->
        invalid("startup_timeout_ms must be a positive integer")

      invalid_timeout?(spec.runtime_timeout_ms) ->
        invalid("runtime_timeout_ms must be :infinity or a positive integer")

      invalid_timeout?(spec.idle_timeout_ms) ->
        invalid("idle_timeout_ms must be :infinity or a positive integer")

      not is_map(spec.metadata) or not is_map(spec.retention) ->
        invalid("metadata and retention must be maps")

      true ->
        case Jido.Harness.RetentionOptions.normalize(spec.retention) do
          {:ok, retention} -> {:ok, %{spec | retention: retention}}
          {:error, _reason} = error -> error
        end
    end
  end

  defp valid_env?({key, value}), do: is_binary(key) and (is_binary(value) or value in [false, nil])
  defp invalid_timeout?(:infinity), do: false
  defp invalid_timeout?(value), do: not (is_integer(value) and value > 0)
  defp invalid(message, details \\ %{}), do: {:error, Jido.Harness.Error.validation(message, details: details)}
end
