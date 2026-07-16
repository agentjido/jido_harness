defmodule Jido.Harness.CLIInventoryTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.CLIInventory

  @expected_tools ~w(claude codex amp gemini antigravity kimi grok pi aider goose opencode)a
  @probe_only ~w(antigravity aider goose)a

  test "records the installed CLI test inventory without registering unsupported adapters" do
    entries = CLIInventory.entries()

    assert Enum.map(entries, & &1.id) == @expected_tools
    assert entries |> Enum.map(& &1.binary) |> Enum.uniq() |> length() == length(entries)
    assert Enum.filter(entries, &is_nil(&1.provider)) |> Enum.map(& &1.id) == @probe_only

    registered = Jido.Harness.providers() |> MapSet.new(& &1.provider)

    assert Enum.all?(entries, fn
             %{provider: nil} -> true
             %{provider: provider} -> MapSet.member?(registered, provider)
           end)

    refute Enum.any?(@probe_only, &MapSet.member?(registered, &1))
  end

  test "extracts every observed version format, including warning output" do
    assert CLIInventory.extract_version(:claude, "2.1.211 (Claude Code)\n") == "2.1.211"
    assert CLIInventory.extract_version(:codex, "codex-cli 0.144.5\n") == "0.144.5"

    assert CLIInventory.extract_version(:amp, "0.0.1784232995-gb305b4 (released today)\n") ==
             "0.0.1784232995-gb305b4"

    assert CLIInventory.extract_version(:grok, "grok 0.2.101 (5bc4b5dfadcf)\n") == "0.2.101"

    assert CLIInventory.extract_version(
             :aider,
             "urllib3 warning: OpenSSL 1.1.1 is unsupported\naider 0.82.3\n"
           ) == "0.82.3"

    assert CLIInventory.extract_version(:goose, " 1.43.0\n") == "1.43.0"
    assert CLIInventory.extract_version(:unknown, "not a version\n") == nil
  end

  test "treats the baseline as a minimum and accepts self-updating tools" do
    assert CLIInventory.compare_version("1.2.3", "1.2.3") == :current
    assert CLIInventory.compare_version("1.3.0", "1.2.3") == :newer
    assert CLIInventory.compare_version("1.2.2", "1.2.3") == :outdated
    assert CLIInventory.compare_version("not-semver", "1.2.3") == :unknown
    assert CLIInventory.compare_version("0.0.1784232995-gb305b4", :latest) == :latest
  end

  test "probes through the managed process runtime and prunes the process" do
    entry = %{
      id: :fixture,
      name: "Fixture",
      binary: "/bin/echo",
      version_argv: ["1.2.3"],
      baseline_version: "1.2.0",
      source: "test fixture",
      update_commands: [],
      provider: nil
    }

    before_ids = Jido.Harness.list_processes() |> MapSet.new(& &1.process_id)
    assert %{installed: true, version: "1.2.3", version_status: :newer} = CLIInventory.probe(entry)
    after_ids = Jido.Harness.list_processes() |> MapSet.new(& &1.process_id)

    assert after_ids == before_ids
  end

  test "reports a missing binary without starting a managed process" do
    entry = %{
      id: :missing_fixture,
      name: "Missing fixture",
      binary: "jido-harness-definitely-not-installed",
      version_argv: ["--version"],
      baseline_version: "1.0.0",
      source: "test fixture",
      update_commands: [],
      provider: nil
    }

    assert %{
             installed: false,
             executable: nil,
             version_status: :missing,
             state: :missing
           } = CLIInventory.probe(entry)
  end
end
