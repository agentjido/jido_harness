defmodule Jido.Harness.AdaptersHelpersTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.{Adapters.Helpers, Error, Process}

  setup do
    directory = Path.join(System.tmp_dir!(), "jido-harness-installer-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory}
  end

  test "script installers return output and prune their managed processes", %{directory: directory} do
    source = installer(directory, "success.sh", "printf installer-ok")
    existing_ids = process_ids()

    assert {:ok, %{provider: :fixture, status: :installed, output: "installer-ok"}} =
             Helpers.install_script(:fixture, file_url(source), timeout: 5_000)

    assert process_ids() == existing_ids
  end

  test "script installer failures include output and prune their managed processes", %{directory: directory} do
    source = installer(directory, "failure.sh", "printf installer-error >&2\nexit 7")
    existing_ids = process_ids()

    assert {:error,
            %Error{
              category: :process,
              details: %{state: :failed, status: 7, output: "installer-error"}
            }} = Helpers.install_script(:fixture, file_url(source), timeout: 5_000)

    assert process_ids() == existing_ids
  end

  defp installer(directory, name, body) do
    path = Path.join(directory, name)
    File.write!(path, "#!/usr/bin/env bash\n#{body}\n")
    path
  end

  defp file_url(path), do: URI.to_string(%URI{scheme: "file", path: path})
  defp process_ids, do: Process.list() |> Enum.map(& &1.process_id) |> Enum.sort()
end
