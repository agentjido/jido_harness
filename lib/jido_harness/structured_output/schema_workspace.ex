defmodule Jido.Harness.StructuredOutput.SchemaWorkspace do
  @moduledoc false

  alias Jido.Harness.{Error, JSONSchema, StructuredOutput}

  @enforce_keys [:directory, :schema_path]
  defstruct [:directory, :schema_path]

  @type t :: %__MODULE__{directory: String.t(), schema_path: String.t()}

  @spec open(StructuredOutput.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def open(%StructuredOutput{} = output, options \\ []) do
    base_directory = Keyword.get(options, :base_directory, default_base_directory())
    directory = Path.join(base_directory, random_name())
    schema_path = Path.join(directory, "schema.json")

    try do
      with {:ok, encoded} <- JSONSchema.encode(output.schema),
           :ok <- prepare_base(base_directory),
           :ok <- File.mkdir(directory),
           :ok <- File.chmod(directory, 0o700),
           :ok <- write_exclusive(schema_path, encoded),
           :ok <- File.chmod(schema_path, 0o600) do
        {:ok, %__MODULE__{directory: directory, schema_path: schema_path}}
      else
        {:error, %Error{} = error} ->
          _ = File.rm_rf(directory)
          {:error, error}

        {:error, _reason} ->
          _ = File.rm_rf(directory)
          workspace_error()
      end
    rescue
      _exception ->
        _ = File.rm_rf(directory)
        workspace_error()
    end
  end

  @spec close(t()) :: :ok | {:error, Error.t()}
  def close(%__MODULE__{directory: directory}) do
    case File.rm_rf(directory) do
      {:ok, _entries} -> :ok
      {:error, _reason, _path} -> workspace_error()
    end
  end

  @spec with_open(StructuredOutput.t(), (t() -> term()), keyword()) :: term() | {:error, Error.t()}
  def with_open(%StructuredOutput{} = output, function, options \\ []) when is_function(function, 1) do
    case open(output, options) do
      {:ok, workspace} ->
        try do
          function.(workspace)
        after
          _ = close(workspace)
        end

      error ->
        error
    end
  end

  defp prepare_base(base_directory) do
    with :ok <- File.mkdir_p(base_directory),
         :ok <- File.chmod(base_directory, 0o700) do
      :ok
    end
  end

  defp write_exclusive(path, encoded) do
    with {:ok, device} <- File.open(path, [:write, :binary, :exclusive]) do
      try do
        IO.binwrite(device, encoded)
      after
        File.close(device)
      end
    end
  end

  defp random_name,
    do: "run-" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false))

  defp default_base_directory,
    do: Path.join(System.tmp_dir!(), "jido-harness-structured-output")

  defp workspace_error,
    do:
      {:error,
       Error.execution("structured-output schema staging failed",
         details: %{failure_kind: :schema_staging_failed}
       )}
end
