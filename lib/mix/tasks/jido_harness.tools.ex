defmodule Mix.Tasks.JidoHarness.Tools do
  @moduledoc """
  Probes the coding-agent CLI test inventory without making provider requests.

      mix jido_harness.tools
      mix jido_harness.tools --tools claude,codex,antigravity
      mix jido_harness.tools --strict
      mix jido_harness.tools --json

  Strict mode fails when a binary is missing, its version command fails, its
  version is unrecognized, or it is older than the recorded test baseline.
  Newer versions pass and are reported as such.

  Antigravity, Aider, and Goose are installation/version probes only. This task
  does not register them as providers or execute agent prompts.
  """
  use Mix.Task

  alias Jido.Harness.CLIInventory

  @shortdoc "Probe the non-billable coding-agent CLI inventory"
  @passing_statuses [:current, :newer, :latest]

  @impl true
  def run(args) do
    {options, rest, invalid} =
      OptionParser.parse(args,
        strict: [tools: :string, strict: :boolean, json: :boolean],
        aliases: [t: :tools]
      )

    if invalid != [] or rest != [] do
      Mix.raise("invalid tools options: #{inspect(invalid ++ Enum.map(rest, &{&1, nil}))}")
    end

    Mix.Task.run("app.start")

    entries = select_tools(options[:tools], CLIInventory.entries())
    rows = Enum.map(entries, &%{entry: &1, result: CLIInventory.probe(&1)})

    if options[:json], do: print_json(rows), else: print_report(rows)
    if options[:strict], do: assert_healthy!(rows)

    :ok
  end

  @doc false
  def select_tools(selector, entries) when selector in [nil, "", "all"], do: entries

  def select_tools(selector, entries) when is_binary(selector) do
    by_id = Map.new(entries, &{Atom.to_string(&1.id), &1})

    names =
      selector
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    unknown = Enum.reject(names, &Map.has_key?(by_id, &1))

    if names == [], do: Mix.raise("--tools must contain at least one tool")

    if unknown != [] do
      available = by_id |> Map.keys() |> Enum.sort() |> Enum.join(",")
      Mix.raise("unknown tools: #{Enum.join(unknown, ",")}; available: #{available}")
    end

    Enum.map(names, &Map.fetch!(by_id, &1))
  end

  @doc false
  def strict_failures(rows) do
    Enum.reject(rows, &(&1.result.version_status in @passing_statuses))
  end

  defp print_report(rows) do
    Mix.shell().info("\nJido.Harness coding-agent CLI inventory")
    Mix.shell().info("tool          binary    installed version       baseline      status       scope")

    Enum.each(rows, fn %{entry: entry, result: result} ->
      fields = [
        entry.id |> Atom.to_string() |> String.pad_trailing(13),
        entry.binary |> String.pad_trailing(9),
        result.installed |> answer() |> String.pad_trailing(9),
        (result.version || "-") |> String.pad_trailing(13),
        baseline(entry.baseline_version) |> String.pad_trailing(13),
        result.version_status |> Atom.to_string() |> String.pad_trailing(12),
        scope(entry)
      ]

      Mix.shell().info(Enum.join(fields, " "))
      if result.error, do: Mix.shell().error("  #{entry.id}: #{result.error}")
    end)

    Mix.shell().info("\nExpected installation sources and update commands")

    Enum.each(rows, fn %{entry: entry, result: result} ->
      Mix.shell().info("  #{entry.id}: #{entry.source}")
      Mix.shell().info("    executable: #{result.executable || "not found"}")
      Enum.each(entry.update_commands, &Mix.shell().info("    update: #{&1}"))
    end)

    probe_only = rows |> Enum.filter(&is_nil(&1.entry.provider)) |> Enum.map(& &1.entry.id)

    if probe_only != [] do
      Mix.shell().info("\nProbe-only tools (no harness adapter): #{Enum.join(probe_only, ", ")}")
    end

    Mix.shell().info("Authentication is not attempted by this version-only inventory check.")

    providers = rows |> Enum.map(& &1.entry.provider) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if providers != [] do
      names = Enum.join(providers, ",")
      Mix.shell().info("\nAll adapter readiness:      mix jido_harness.live")
      Mix.shell().info("Selected adapter readiness: mix jido_harness.live --providers #{names}")
      Mix.shell().info("Selected live smoke tests:  mix jido_harness.live --providers #{names} --test --profile smoke")
    end
  end

  defp print_json(rows) do
    report =
      Enum.map(rows, fn %{entry: entry, result: result} ->
        entry
        |> Map.put(:baseline_version, baseline(entry.baseline_version))
        |> Map.merge(result)
      end)

    Mix.shell().info(Jason.encode!(report, pretty: true))
  end

  defp assert_healthy!(rows) do
    case strict_failures(rows) do
      [] -> :ok
      failures -> Mix.raise("CLI inventory failed: #{Enum.map_join(failures, ",", & &1.entry.id)}")
    end
  end

  defp scope(%{provider: nil}), do: "probe-only"
  defp scope(%{provider: provider}), do: "adapter:#{provider}"
  defp baseline(:latest), do: "latest"
  defp baseline(version), do: version
  defp answer(true), do: "yes"
  defp answer(false), do: "no"
end
