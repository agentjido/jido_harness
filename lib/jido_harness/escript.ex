defmodule Jido.Harness.Escript do
  @moduledoc """
  Bootstraps the native `erlexec` helper from a Mix escript archive.

  Mix can include the `erlexec` private directory in an escript, but the native
  `exec-port` file cannot run from inside the archive. `bootstrap_erlexec/1`
  selects the file for the current system architecture, copies it to a private
  user-cache directory, makes it executable, and configures `:erlexec` to use
  that path.

  Call this function before `:erlexec` or `:jido_harness` starts. The escript
  must use `app: nil` and `include_priv_for: [:erlexec]`.

      def main(_args) do
        with {:ok, _path} <- Jido.Harness.Escript.bootstrap_erlexec(),
             {:ok, _apps} <- Application.ensure_all_started(:jido_harness) do
          run_cli()
        end
      end

  See the [escript packaging guide](escripts.html) for the complete Mix
  configuration.
  """

  alias Jido.Harness.Error

  @executable "exec-port"

  @doc """
  Extracts and configures the `erlexec` helper for the current escript.

  Options:

  * `:escript_path` overrides `:escript.script_name/0`. This is useful for
    custom launchers and tests.
  * `:cache_dir` overrides the user-cache base directory. The helper is stored
    below an architecture and content-specific subdirectory.

  The function is idempotent for the same helper content. It must run before
  `:erlexec` starts.
  """
  @spec bootstrap_erlexec(keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def bootstrap_erlexec(options \\ [])

  def bootstrap_erlexec(options) when is_list(options) do
    if Keyword.keyword?(options) do
      with {:ok, escript_path} <- option_path(options, :escript_path, default_escript_path()),
           {:ok, cache_dir} <- option_path(options, :cache_dir, default_cache_dir()),
           :ok <- ensure_erlexec_stopped(),
           {:ok, archive} <- extract_archive(escript_path),
           {:ok, helper} <- find_helper(archive),
           {:ok, path} <- cache_helper(cache_dir, helper) do
        Application.put_env(:erlexec, :portexe, path)
        {:ok, path}
      end
    else
      configuration_error("escript bootstrap options must be a keyword list")
    end
  rescue
    exception ->
      configuration_error("could not bootstrap erlexec from the escript",
        cause: exception,
        details: %{message: Exception.message(exception)}
      )
  catch
    kind, reason ->
      configuration_error("could not bootstrap erlexec from the escript",
        cause: {kind, reason},
        details: %{reason: inspect(reason)}
      )
  end

  def bootstrap_erlexec(_options),
    do: configuration_error("escript bootstrap options must be a keyword list")

  defp default_escript_path, do: :escript.script_name()
  defp default_cache_dir, do: :filename.basedir(:user_cache, "jido_harness")

  defp option_path(options, key, default) do
    case Keyword.get(options, key, default) do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      path when is_list(path) and path != [] -> {:ok, path |> List.to_string() |> Path.expand()}
      _value -> configuration_error("#{key} must be a non-empty path", details: %{option: key})
    end
  end

  defp ensure_erlexec_stopped do
    if not is_nil(Process.whereis(:exec)) or application_started?(:erlexec) do
      configuration_error("erlexec is already started; bootstrap it before starting jido_harness")
    else
      :ok
    end
  end

  defp application_started?(application) do
    Enum.any?(Application.started_applications(), fn {started, _description, _version} ->
      started == application
    end)
  end

  defp extract_archive(escript_path) do
    case :escript.extract(String.to_charlist(escript_path), []) do
      {:ok, sections} ->
        case List.keyfind(sections, :archive, 0) do
          {:archive, archive} when is_binary(archive) -> {:ok, archive}
          _missing -> configuration_error("escript does not contain an archive", details: %{path: escript_path})
        end

      {:error, reason} ->
        configuration_error("could not read the escript archive",
          details: %{path: escript_path, reason: inspect(reason)}
        )
    end
  end

  defp find_helper(archive) do
    architecture = :erlang.system_info(:system_architecture) |> List.to_string()

    case archive_helpers(archive) do
      {:ok, helpers} ->
        select_helper(helpers, architecture)

      {:error, reason} ->
        configuration_error("could not inspect the escript archive", details: %{reason: inspect(reason)})
    end
  end

  defp archive_helpers(archive) do
    :zip.foldl(
      fn name, _get_info, get_binary, helpers ->
        path = to_string(name)
        if Path.basename(path) == @executable, do: [{path, get_binary.()} | helpers], else: helpers
      end,
      [],
      {~c"jido-harness-escript.zip", archive}
    )
  end

  defp select_helper(helpers, architecture) do
    matches = Enum.filter(helpers, fn {path, _binary} -> helper_for_architecture?(path, architecture) end)

    case matches do
      [{_path, binary}] ->
        {:ok, %{architecture: architecture, binary: binary}}

      [] ->
        configuration_error("escript does not contain an erlexec helper for the current architecture",
          details: %{architecture: architecture, entries: Enum.map(helpers, &elem(&1, 0))}
        )

      many ->
        configuration_error("escript contains multiple erlexec helpers for the current architecture",
          details: %{architecture: architecture, entries: Enum.map(many, &elem(&1, 0))}
        )
    end
  end

  defp helper_for_architecture?(path, architecture) do
    path
    |> String.split("/", trim: true)
    |> Enum.chunk_every(4, 1, :discard)
    |> Enum.any?(&(&1 == ["erlexec", "priv", architecture, @executable]))
  end

  defp cache_helper(cache_dir, %{architecture: architecture, binary: binary}) do
    fingerprint = "#{byte_size(binary)}-#{Integer.to_string(:erlang.phash2(binary), 16)}"
    directory = Path.join([cache_dir, "erlexec", architecture, fingerprint])
    target = Path.join(directory, @executable)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- store_helper(target, binary),
         :ok <- File.chmod(target, 0o700) do
      {:ok, target}
    else
      {:error, reason} ->
        configuration_error("could not write the erlexec helper to the cache",
          details: %{path: target, reason: inspect(reason)}
        )
    end
  end

  defp store_helper(target, binary) do
    case File.read(target) do
      {:ok, ^binary} -> :ok
      _missing_or_changed -> atomic_write(target, binary)
    end
  end

  defp atomic_write(target, binary) do
    temporary = target <> ".tmp-#{System.pid()}-#{System.unique_integer([:positive])}"

    try do
      with :ok <- File.write(temporary, binary, [:binary, :exclusive]),
           :ok <- File.chmod(temporary, 0o700),
           :ok <- replace_file(temporary, target) do
        :ok
      end
    after
      File.rm(temporary)
    end
  end

  defp replace_file(source, target) do
    case File.rename(source, target) do
      :ok ->
        :ok

      {:error, :eexist} ->
        with :ok <- File.rm(target), do: File.rename(source, target)

      error ->
        error
    end
  end

  defp configuration_error(message, options \\ []) do
    {:error, Error.new(:configuration, message, options)}
  end
end
