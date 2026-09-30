defmodule Mix.Tasks.Compile.HarnessNative do
  @moduledoc false
  use Mix.Task.Compiler

  @source Path.join(__DIR__, "c_src")
  @build_variables ~w(CXX CXXFLAGS CPPFLAGS LDFLAGS ADD_FLAGS OPTIMIZE USE_POLL CROSS_COMPILE)

  @impl true
  def run(arguments) do
    architecture = :erlang.system_info(:system_architecture) |> to_string()
    output = Path.expand(Path.join(["priv", "native", architecture, "exec-port"]))
    license_path = Path.join(Path.dirname(Path.dirname(output)), "LICENSE")
    license = File.read!(Path.join(__DIR__, "LICENSE"))

    if File.read(license_path) != {:ok, license} do
      File.mkdir_p!(Path.dirname(license_path))
      File.write!(license_path, license)
    end

    Mix.Project.build_structure()

    interface =
      case Path.wildcard(Path.join([to_string(:code.root_dir()), "lib", "erl_interface-*"])) do
        [directory] ->
          directory

        _other ->
          Mix.raise("Erlang's erl_interface headers and library are required to build the Harness native helper")
      end

    environment = [
      {"ERL_CXXFLAGS", "-I" <> quote_path(Path.join(interface, "include"))},
      {"ERL_LDFLAGS", "-L" <> quote_path(Path.join(interface, "lib"))}
    ]

    fingerprint =
      {@source |> Path.join("*") |> Path.wildcard() |> Enum.map(&{&1, File.read!(&1)}), File.read!(__ENV__.file),
       environment, architecture, :erlang.system_info(:version), Enum.map(@build_variables, &{&1, System.get_env(&1)})}
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))

    [manifest] = manifests()

    if "--force" not in arguments and File.read(manifest) == {:ok, fingerprint} and File.regular?(output) do
      {:noop, []}
    else
      build(output, environment, fingerprint, manifest)
    end
  end

  defp build(output, environment, fingerprint, manifest) do
    make =
      System.find_executable("gmake") || System.find_executable("make") ||
        Mix.raise("Building the Harness native helper requires make and a C++17 compiler")

    directory = Path.join(Mix.Project.manifest_path(), "harness_native")
    File.rm_rf!(directory)
    File.mkdir_p!(Path.dirname(directory))
    File.cp_r!(@source, directory)
    File.mkdir_p!(Path.dirname(output))

    Mix.shell().info("Compiling the Harness native process helper")

    {log, status} =
      System.cmd(make, ["-C", directory, "EXE_OUTPUT=exec-port"], env: environment, stderr_to_stdout: true)

    Mix.shell().info(log)

    if status == 0 do
      temporary = output <> ".#{System.unique_integer([:positive])}.tmp"

      try do
        File.cp!(Path.join(directory, "exec-port"), temporary)
        File.rename!(temporary, output)
      after
        File.rm(temporary)
      end

      File.write!(manifest, fingerprint)
      {:ok, []}
    else
      {:error,
       [
         %Mix.Task.Compiler.Diagnostic{
           compiler_name: "harness_native",
           file: Path.join(@source, "Makefile"),
           position: 0,
           message: "Native process helper build failed (exit #{status})",
           severity: :error
         }
       ]}
    end
  end

  defp quote_path(path), do: "'" <> String.replace(to_string(path), "'", "'\"'\"'") <> "'"

  @impl true
  def manifests, do: [Path.join(Mix.Project.manifest_path(), "compile.harness_native")]

  @impl true
  def clean do
    Enum.each(manifests(), &File.rm/1)
    File.rm_rf!(Path.join(Mix.Project.manifest_path(), "harness_native"))
    File.rm_rf!(Path.expand("priv/native"))
  end
end
