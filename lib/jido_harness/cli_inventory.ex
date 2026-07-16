defmodule Jido.Harness.CLIInventory do
  @moduledoc """
  Non-billable installation and version probes for the local coding-agent CLI inventory.

  Inventory entries with a `provider` participate in the full harness contract suite.
  Entries without one are diagnostic probes only and are deliberately not registered as
  harness adapters.
  """

  alias Jido.Harness.{ProcessInfo, ProcessSpec}

  @type entry :: %{
          required(:id) => atom(),
          required(:name) => String.t(),
          required(:binary) => String.t(),
          required(:version_argv) => [String.t()],
          required(:baseline_version) => String.t() | :latest,
          required(:source) => String.t(),
          required(:update_commands) => [String.t()],
          required(:provider) => atom() | nil
        }

  @type version_status :: :current | :newer | :outdated | :latest | :unknown

  @type probe_result :: %{
          required(:tool) => atom(),
          required(:installed) => boolean(),
          required(:executable) => String.t() | nil,
          required(:version) => String.t() | nil,
          required(:version_status) => version_status() | :missing | :probe_failed,
          required(:state) => atom(),
          required(:exit_status) => integer() | nil,
          required(:error) => String.t() | nil
        }

  @entries [
    %{
      id: :claude,
      name: "Claude Code",
      binary: "claude",
      version_argv: ["--version"],
      baseline_version: "2.1.211",
      source: "native (~/.local/bin)",
      update_commands: ["claude update"],
      provider: :claude
    },
    %{
      id: :codex,
      name: "Codex",
      binary: "codex",
      version_argv: ["--version"],
      baseline_version: "0.144.5",
      source: "Homebrew cask",
      update_commands: ["brew upgrade --cask codex"],
      provider: :codex
    },
    %{
      id: :amp,
      name: "Amp",
      binary: "amp",
      version_argv: ["--version"],
      baseline_version: :latest,
      source: "native (~/.local/bin)",
      update_commands: ["Amp updates itself"],
      provider: :amp
    },
    %{
      id: :gemini,
      name: "Gemini CLI",
      binary: "gemini",
      version_argv: ["--version"],
      baseline_version: "0.51.0",
      source: "npm @google/gemini-cli",
      update_commands: ["npm update --global @google/gemini-cli"],
      provider: :gemini
    },
    %{
      id: :antigravity,
      name: "Antigravity CLI",
      binary: "agy",
      version_argv: ["--version"],
      baseline_version: "1.1.3",
      source: "Homebrew cask",
      update_commands: ["brew upgrade --cask antigravity-cli"],
      provider: nil
    },
    %{
      id: :kimi,
      name: "Kimi Code",
      binary: "kimi",
      version_argv: ["--version"],
      baseline_version: "0.24.2",
      source: "Homebrew kimi-code",
      update_commands: ["brew upgrade kimi-code", "kimi upgrade"],
      provider: :kimi
    },
    %{
      id: :grok,
      name: "Grok",
      binary: "grok",
      version_argv: ["version"],
      baseline_version: "0.2.101",
      source: "npm @xai-official/grok",
      update_commands: ["npm update --global @xai-official/grok"],
      provider: :grok
    },
    %{
      id: :pi,
      name: "pi-coding-agent",
      binary: "pi",
      version_argv: ["--version"],
      baseline_version: "0.80.10",
      source: "npm @earendil-works/pi-coding-agent",
      update_commands: ["npm update --global @earendil-works/pi-coding-agent"],
      provider: :pi
    },
    %{
      id: :aider,
      name: "Aider",
      binary: "aider",
      version_argv: ["--version"],
      baseline_version: "0.82.3",
      source: "pip3 (~/.local/bin)",
      update_commands: ["pip3 install --upgrade aider-chat"],
      provider: nil
    },
    %{
      id: :goose,
      name: "Goose",
      binary: "goose",
      version_argv: ["--version"],
      baseline_version: "1.43.0",
      source: "Homebrew block-goose-cli",
      update_commands: ["brew upgrade block-goose-cli"],
      provider: nil
    },
    %{
      id: :opencode,
      name: "OpenCode",
      binary: "opencode",
      version_argv: ["--version"],
      baseline_version: "1.18.0",
      source: "Homebrew opencode",
      update_commands: ["brew upgrade opencode", "opencode upgrade"],
      provider: :opencode
    }
  ]

  @version_patterns %{
    claude: ~r/^([0-9][^\s]*)\s+\(Claude Code\)/m,
    codex: ~r/^codex-cli\s+([0-9][^\s]*)/mi,
    grok: ~r/^grok\s+([0-9][^\s]*)/mi,
    aider: ~r/^aider\s+([0-9][^\s]*)/mi
  }

  @doc "Returns the ordered coding-agent CLI inventory used by diagnostic tests."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "Finds an inventory entry by its stable atom identifier."
  @spec fetch(atom()) :: {:ok, entry()} | :error
  def fetch(id) when is_atom(id) do
    case Enum.find(@entries, &(&1.id == id)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc "Runs an entry's version command through the managed process runtime."
  @spec probe(atom() | entry(), keyword()) :: probe_result()
  def probe(entry_or_id, options \\ []) do
    timeout = Keyword.get(options, :timeout, 20_000)

    with {:ok, entry} <- normalize_entry(entry_or_id),
         {:ok, executable} <- ProcessSpec.resolve_executable(entry.binary) do
      run_probe(entry, executable, timeout)
    else
      :error -> missing_result(entry_or_id, "unknown inventory tool")
      {:error, error} -> missing_result(entry_or_id, format_error(error))
    end
  end

  @doc "Extracts a normalized version from a tool's version-command output."
  @spec extract_version(atom(), String.t()) :: String.t() | nil
  def extract_version(tool, output) when is_atom(tool) and is_binary(output) do
    output = strip_ansi(output)

    pattern =
      Map.get(
        @version_patterns,
        tool,
        ~r/^[ \t]*v?([0-9]+(?:\.[0-9]+){1,3}(?:[-+][0-9A-Za-z.-]+)?)(?:\s|$)/m
      )

    case Regex.run(pattern, output, capture: :all_but_first) do
      [version | _] -> String.trim_trailing(version, ",")
      _ -> nil
    end
  end

  @doc "Compares an observed CLI version with the inventory baseline."
  @spec compare_version(String.t() | nil, String.t() | :latest) :: version_status()
  def compare_version(nil, _baseline), do: :unknown
  def compare_version(_version, :latest), do: :latest

  def compare_version(version, baseline) when is_binary(version) and is_binary(baseline) do
    with {:ok, parsed_version} <- Version.parse(version),
         {:ok, parsed_baseline} <- Version.parse(baseline) do
      case Version.compare(parsed_version, parsed_baseline) do
        :eq -> :current
        :gt -> :newer
        :lt -> :outdated
      end
    else
      :error -> :unknown
    end
  end

  defp run_probe(entry, executable, timeout) do
    spec = %{
      executable: executable,
      argv: entry.version_argv,
      stdin: false,
      runtime_timeout_ms: timeout,
      idle_timeout_ms: timeout,
      metadata: %{purpose: "cli_inventory", tool: Atom.to_string(entry.id)},
      retention: %{memory_bytes: 65_536, disk_limit_bytes: 262_144}
    }

    case Jido.Harness.start_process(spec) do
      {:ok, process_id} -> collect_probe(entry, executable, process_id, timeout)
      {:error, error} -> failed_result(entry, executable, :start_failed, nil, format_error(error))
    end
  end

  defp collect_probe(entry, executable, process_id, timeout) do
    awaited =
      process_id
      |> Jido.Harness.await_process(timeout + 1_000)
      |> finish_timed_out_probe(process_id)

    info = terminal_info(process_id, awaited)
    output = replay_output(process_id)
    _ = prune_probe(process_id, info)

    case info do
      %ProcessInfo{state: :exited, exit_status: 0} ->
        version = extract_version(entry.id, output)

        %{
          tool: entry.id,
          installed: true,
          executable: executable,
          version: version,
          version_status: compare_version(version, entry.baseline_version),
          state: :exited,
          exit_status: 0,
          error: if(version, do: nil, else: "version output was not recognized")
        }

      %ProcessInfo{} = process_info ->
        failed_result(
          entry,
          executable,
          process_info.state,
          process_info.exit_status,
          format_error(process_info.error || "version probe failed")
        )

      _other ->
        failed_result(entry, executable, :probe_failed, nil, "version probe did not return process information")
    end
  end

  defp finish_timed_out_probe({:error, :timeout}, process_id) do
    _ = Jido.Harness.cancel_process(process_id)

    case Jido.Harness.await_process(process_id, 12_000) do
      {:error, :timeout} ->
        _ = Jido.Harness.kill_process(process_id)
        Jido.Harness.await_process(process_id, 2_000)

      result ->
        result
    end
  end

  defp finish_timed_out_probe(result, _process_id), do: result

  defp terminal_info(_process_id, {:ok, %ProcessInfo{} = info}), do: info

  defp terminal_info(process_id, _awaited) do
    case Jido.Harness.info_process(process_id) do
      {:ok, %ProcessInfo{} = info} -> info
      _ -> nil
    end
  end

  defp replay_output(process_id) do
    case Jido.Harness.replay_process(process_id, limit: 1_000) do
      {:ok, events} ->
        events
        |> Enum.filter(&(&1.type in [:stdout, :stderr]))
        |> Enum.map(& &1.data)
        |> Enum.filter(&is_binary/1)
        |> IO.iodata_to_binary()

      _ ->
        ""
    end
  end

  defp prune_probe(process_id, %ProcessInfo{} = info) do
    if ProcessInfo.terminal?(info), do: Jido.Harness.prune_process(process_id), else: :ok
  end

  defp prune_probe(_process_id, _info), do: :ok

  defp normalize_entry(id) when is_atom(id), do: fetch(id)

  defp normalize_entry(%{} = entry) do
    required = [:id, :name, :binary, :version_argv, :baseline_version, :source, :update_commands, :provider]

    if Enum.all?(required, &Map.has_key?(entry, &1)), do: {:ok, entry}, else: :error
  end

  defp normalize_entry(_entry), do: :error

  defp missing_result(entry_or_id, error) do
    %{
      tool: tool_id(entry_or_id),
      installed: false,
      executable: nil,
      version: nil,
      version_status: :missing,
      state: :missing,
      exit_status: nil,
      error: error
    }
  end

  defp failed_result(entry, executable, state, exit_status, error) do
    %{
      tool: entry.id,
      installed: true,
      executable: executable,
      version: nil,
      version_status: :probe_failed,
      state: state,
      exit_status: exit_status,
      error: error
    }
  end

  defp tool_id(%{id: id}) when is_atom(id), do: id
  defp tool_id(id) when is_atom(id), do: id
  defp tool_id(_entry), do: :unknown

  defp strip_ansi(output), do: Regex.replace(~r/\e\[[0-9;]*[[:alpha:]]/, output, "")
  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error, limit: 10, printable_limit: 500)
end
