defmodule Jido.Harness.EscriptTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Jido.Harness.Error

  @child_code """
  [escript_path, cache_dir] = System.argv()
  Application.put_env(:jido_harness, :process_manager, %{journal_dir: Path.join(cache_dir, "journals")})

  with {:ok, helper_path} <-
         Jido.Harness.Escript.bootstrap_erlexec(escript_path: escript_path, cache_dir: cache_dir),
       {:ok, _applications} <- Application.ensure_all_started(:jido_harness) do
    IO.puts("BOOTSTRAP_OK=" <> helper_path)
  else
    {:error, error} ->
      IO.puts(:stderr, Exception.message(error))
      System.halt(1)
  end
  """

  setup do
    directory =
      Path.join(System.tmp_dir!(), "jido-harness-escript-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory}
  end

  test "a Mix escript extracts the current helper and starts jido_harness", %{directory: directory} do
    architecture = :erlang.system_info(:system_architecture) |> List.to_string()
    source = Path.join([:erlexec |> :code.priv_dir() |> List.to_string(), architecture, "exec-port"])
    binary = File.read!(source)
    {escript_path, environment} = build_escript(directory)
    {output, 0} = System.cmd(escript_path, [], env: environment, stderr_to_stdout: true)
    [helper_path] = Regex.run(~r/BOOTSTRAP_OK=(.+)/, output, capture: :all_but_first)

    assert File.read!(helper_path) == binary
    assert {:ok, stat} = File.stat(helper_path)
    assert (stat.mode &&& 0o111) != 0
    assert String.starts_with?(helper_path, Path.join([directory, "erlexec", architecture]))
  end

  test "rejects an archive without a helper for the current architecture", %{directory: directory} do
    escript_path = Path.join(directory, "wrong-architecture.escript")

    assert :ok =
             :escript.create(String.to_charlist(escript_path), [
               :shebang,
               {:archive, [{~c"erlexec/priv/wrong-architecture/exec-port", "not-executable"}], []}
             ])

    {output, status} = run_child(escript_path, directory)
    assert status == 1
    assert output =~ "does not contain an erlexec helper for the current architecture"
  end

  test "rejects invalid options and calls after erlexec starts", %{directory: directory} do
    assert {:error, %Error{category: :configuration, message: "escript bootstrap options must be a keyword list"}} =
             Jido.Harness.Escript.bootstrap_erlexec(:invalid)

    assert {:error, %Error{category: :configuration, message: "escript bootstrap options must be a keyword list"}} =
             Jido.Harness.Escript.bootstrap_erlexec([:invalid])

    assert {:error, %Error{category: :configuration, message: message}} =
             Jido.Harness.Escript.bootstrap_erlexec(escript_path: "unused", cache_dir: directory)

    assert message =~ "erlexec is already started"
  end

  defp run_child(escript_path, cache_dir) do
    executable = System.find_executable("elixir") || raise "elixir executable is unavailable"

    code_paths =
      "_build/test/lib/*/ebin"
      |> Path.expand(File.cwd!())
      |> Path.wildcard()
      |> Enum.flat_map(&["-pa", &1])

    System.cmd(
      executable,
      code_paths ++ ["-e", @child_code, "--", escript_path, cache_dir],
      env: [{"SHELL", System.get_env("SHELL") || "/bin/sh"}],
      stderr_to_stdout: true
    )
  end

  defp build_escript(directory) do
    fixture = Path.expand("../../fixtures/escript_fixture", __DIR__)
    escript_path = Path.join(directory, "jido-harness-escript-fixture")

    environment = [
      {"JIDO_HARNESS_ESCRIPT_CACHE_DIR", directory},
      {"JIDO_HARNESS_ESCRIPT_PATH", escript_path},
      {"MIX_BUILD_PATH", Path.expand("_build/test", File.cwd!())},
      {"MIX_DEPS_PATH", Path.expand("deps", File.cwd!())},
      {"MIX_ENV", "test"},
      {"SHELL", System.get_env("SHELL") || "/bin/sh"}
    ]

    assert {_output, 0} = System.cmd("mix", ["deps.get"], cd: fixture, env: environment, stderr_to_stdout: true)
    assert {_output, 0} = System.cmd("mix", ["escript.build"], cd: fixture, env: environment, stderr_to_stdout: true)

    {escript_path, environment}
  end
end
