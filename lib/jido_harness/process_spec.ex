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

  @enforce_keys [:executable]
  defstruct executable: nil,
            argv: [],
            cwd: nil,
            env: %{},
            env_mode: :overlay,
            stdin: true,
            pty: false,
            startup_timeout_ms: 15_000,
            runtime_timeout_ms: :infinity,
            idle_timeout_ms: :infinity,
            metadata: %{},
            retention: %{},
            lifecycle_owner: nil

  @type t :: %__MODULE__{
          executable: String.t(),
          argv: [String.t()],
          cwd: String.t(),
          env: %{optional(String.t()) => String.t() | false | nil},
          env_mode: :overlay | :replace,
          stdin: boolean(),
          pty: boolean() | keyword(),
          startup_timeout_ms: pos_integer(),
          runtime_timeout_ms: pos_integer() | :infinity,
          idle_timeout_ms: pos_integer() | :infinity,
          metadata: map(),
          retention: map(),
          lifecycle_owner: pid() | nil
        }

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  @doc "Validates and constructs a shell-free process specification."
  def new(%__MODULE__{} = spec), do: validate(spec)

  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    case Enum.find(Map.keys(attrs), &(&1 not in @keys)) do
      nil ->
        attrs = Map.put_new(attrs, :cwd, File.cwd!())

        try do
          attrs |> then(&struct!(__MODULE__, &1)) |> validate()
        rescue
          error in [ArgumentError, KeyError] ->
            {:error,
             Jido.Harness.Error.validation("invalid process specification",
               details: %{reason: Exception.message(error)}
             )}
        end

      key ->
        {:error, Jido.Harness.Error.validation("unknown process option", details: %{key: key})}
    end
  end

  def new(other),
    do:
      {:error, Jido.Harness.Error.validation("process specification must be a map", details: %{value: inspect(other)})}

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
        {:ok, spec}
    end
  end

  defp valid_env?({key, value}), do: is_binary(key) and (is_binary(value) or value in [false, nil])
  defp invalid_timeout?(:infinity), do: false
  defp invalid_timeout?(value), do: not (is_integer(value) and value > 0)
  defp invalid(message, details \\ %{}), do: {:error, Jido.Harness.Error.validation(message, details: details)}
end
