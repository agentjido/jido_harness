defmodule Mix.Tasks.JidoHarness.Check do
  @moduledoc """
  Checks provider readiness and the local coding-agent CLI inventory.

  The default operation is a non-billable readiness check for registered
  providers:

      mix jido_harness.check
      mix jido_harness.check --providers codex,kimi

  Installation is explicit. The complete version inventory, including tools
  without adapters, is also opt-in:

      mix jido_harness.check --providers codex,kimi --install
      mix jido_harness.check --inventory
      mix jido_harness.check --tools claude,codex,antigravity --strict
      mix jido_harness.check --inventory --json

  This task never sends an agent prompt. Use `jido_harness.query`,
  `jido_harness.chat`, or `jido_harness.integration` for live provider work.
  """
  use Mix.Task

  alias Jido.Harness.{AdapterSpec, CLIInventory, ProviderStatus}

  @shortdoc "Check harness readiness, installation, and CLI versions"
  @passing_inventory_statuses [:current, :newer, :latest]

  @impl true
  def run(args) do
    {options, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          providers: :string,
          tools: :string,
          inventory: :boolean,
          strict: :boolean,
          json: :boolean,
          env_file: :string,
          install: :boolean
        ],
        aliases: [p: :providers, t: :tools]
      )

    if invalid != [] or rest != [] do
      Mix.raise("invalid check options: #{inspect(invalid ++ Enum.map(rest, &{&1, nil}))}")
    end

    if options[:json] && options[:install] do
      Mix.raise("--json and --install cannot be combined")
    end

    if path = options[:env_file], do: Mix.Tasks.JidoHarness.Integration.load_env_file(path)

    Mix.Task.run("app.start")

    specs = select_providers(options[:providers], Jido.Harness.providers())
    provider_rows = probe_providers(specs)

    provider_rows =
      if options[:install] do
        install_unavailable(provider_rows)
        probe_providers(specs)
      else
        provider_rows
      end

    inventory_rows =
      if options[:inventory] || options[:tools] do
        options[:tools]
        |> select_tools(CLIInventory.entries())
        |> Enum.map(&%{entry: &1, result: CLIInventory.probe(&1)})
      else
        []
      end

    if options[:json] do
      print_json(provider_rows, inventory_rows)
    else
      print_provider_report(provider_rows)
      print_install_guidance(provider_rows)
      if inventory_rows != [], do: print_inventory_report(inventory_rows)
      print_next_steps(specs, inventory_rows == [])
    end

    if options[:strict], do: assert_healthy!(provider_rows, inventory_rows)
    :ok
  end

  @doc false
  def select_providers(selector, specs) when selector in [nil, "", "all"], do: specs

  def select_providers(selector, specs) when is_binary(selector) do
    by_name = Map.new(specs, &{Atom.to_string(&1.provider), &1})
    names = selected_names(selector, "--providers")
    reject_unknown!(names, by_name, "providers")
    Enum.map(names, &Map.fetch!(by_name, &1))
  end

  @doc false
  def select_tools(selector, entries) when selector in [nil, "", "all"], do: entries

  def select_tools(selector, entries) when is_binary(selector) do
    by_name = Map.new(entries, &{Atom.to_string(&1.id), &1})
    names = selected_names(selector, "--tools")
    reject_unknown!(names, by_name, "tools")
    Enum.map(names, &Map.fetch!(by_name, &1))
  end

  @doc false
  def install_command(%AdapterSpec{install: %{npm: package, npm_args: args}})
      when is_binary(package) and is_list(args),
      do: Enum.join(["npm", "install", "--global"] ++ args ++ [package], " ")

  def install_command(%AdapterSpec{install: %{npm: package}}) when is_binary(package),
    do: "npm install --global #{package}"

  def install_command(%AdapterSpec{}), do: nil

  @doc false
  def strict_inventory_failures(rows),
    do: Enum.reject(rows, &(&1.result.version_status in @passing_inventory_statuses))

  defp selected_names(selector, option) do
    names =
      selector
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if names == [], do: Mix.raise("#{option} must contain at least one name")
    names
  end

  defp reject_unknown!(names, entries, kind) do
    unknown = Enum.reject(names, &Map.has_key?(entries, &1))

    if unknown != [] do
      available = entries |> Map.keys() |> Enum.sort() |> Enum.join(",")
      Mix.raise("unknown #{kind}: #{Enum.join(unknown, ",")}; available: #{available}")
    end
  end

  defp probe_providers(specs) do
    Enum.map(specs, fn spec -> %{spec: spec, result: safe_status(spec.provider)} end)
  end

  defp safe_status(provider) do
    Jido.Harness.status(provider)
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp install_unavailable(rows) do
    Enum.each(rows, fn
      %{result: {:ok, %ProviderStatus{smoke_ready: true}}} ->
        :ok

      %{spec: spec} ->
        case install_command(spec) do
          nil ->
            Mix.shell().error(
              "#{spec.name} has no automatic installation recipe; see #{spec.docs_url || "provider docs"}"
            )

          command ->
            Mix.shell().info("Installing #{spec.name} with #{command}")

            case Jido.Harness.install(spec.provider) do
              {:ok, _result} -> Mix.shell().info("Installed #{spec.name}")
              {:error, error} -> Mix.shell().error("Could not install #{spec.name}: #{format_error(error)}")
            end
        end
    end)
  end

  defp print_provider_report(rows) do
    Mix.shell().info("\nJido.Harness provider readiness")
    Mix.shell().info("provider    installed compatible auth     ready version")

    Enum.each(rows, fn
      %{spec: spec, result: {:ok, %ProviderStatus{} = status}} ->
        fields = [
          spec.provider |> Atom.to_string() |> String.pad_trailing(11),
          status.installed |> answer() |> String.pad_trailing(10),
          status.compatible |> answer() |> String.pad_trailing(11),
          status.authenticated |> answer() |> String.pad_trailing(8),
          status.smoke_ready |> answer() |> String.pad_trailing(5),
          status.version || "-"
        ]

        Mix.shell().info(Enum.join(fields, " "))

      %{spec: spec, result: result} ->
        provider = spec.provider |> Atom.to_string() |> String.pad_trailing(11)
        Mix.shell().info("#{provider} error: #{format_error(result)}")
    end)
  end

  defp print_install_guidance(rows) do
    unavailable = Enum.reject(rows, &provider_ready?/1)

    if unavailable != [] do
      Mix.shell().info("\nInstall or upgrade unavailable providers")

      Enum.each(unavailable, fn %{spec: spec} ->
        command = install_command(spec) || "No automatic recipe; follow the provider documentation"
        Mix.shell().info("  #{spec.provider}: #{command}")
        if spec.docs_url, do: Mix.shell().info("       #{spec.docs_url}")
      end)

      providers = unavailable |> Enum.map(& &1.spec.provider) |> Enum.join(",")
      Mix.shell().info("  Managed install: mix jido_harness.check --providers #{providers} --install")
    end

    if Enum.any?(rows, &unknown_auth?/1) do
      Mix.shell().info("\nAuth 'unknown' means no recognized API-key environment variable was set.")
      Mix.shell().info("Cached CLI login may still be valid; a live smoke test is definitive.")
    end
  end

  defp print_inventory_report(rows) do
    Mix.shell().info("\nCoding-agent CLI inventory")
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
    if probe_only != [], do: Mix.shell().info("\nProbe-only tools (no harness adapter): #{Enum.join(probe_only, ", ")}")
  end

  defp print_next_steps(specs, inventory_omitted?) do
    providers = specs |> Enum.map(& &1.provider) |> Enum.join(",")

    if inventory_omitted? do
      Mix.shell().info("\nFull version inventory (including probe-only tools)")
      Mix.shell().info("  mix jido_harness.check --inventory --strict")
    end

    Mix.shell().info("\nLive testing (may contact providers and incur usage)")
    Mix.shell().info("  Query:       mix jido_harness.query #{providers} \"Reply with exactly: ready\" --expect ready")
    Mix.shell().info("  Smoke:       mix jido_harness.integration --providers #{providers} --profile smoke")
    Mix.shell().info("  Interactive: mix jido_harness.chat #{List.first(String.split(providers, ","))}")
  end

  defp print_json(provider_rows, inventory_rows) do
    report = %{
      providers:
        Enum.map(provider_rows, fn %{spec: spec, result: result} ->
          %{
            provider: spec.provider,
            name: spec.name,
            docs_url: spec.docs_url,
            install: install_command(spec),
            status: json_value(result)
          }
        end),
      inventory:
        Enum.map(inventory_rows, fn %{entry: entry, result: result} ->
          entry
          |> Map.put(:baseline_version, baseline(entry.baseline_version))
          |> Map.merge(result)
        end)
    }

    Mix.shell().info(Jason.encode!(report, pretty: true))
  end

  defp assert_healthy!(provider_rows, inventory_rows) do
    providers = Enum.reject(provider_rows, &provider_ready?/1)
    inventory = strict_inventory_failures(inventory_rows)

    failures =
      Enum.map(providers, &Atom.to_string(&1.spec.provider)) ++
        Enum.map(inventory, &Atom.to_string(&1.entry.id))

    if failures != [], do: Mix.raise("harness check failed: #{Enum.join(failures, ",")}")
  end

  defp provider_ready?(%{result: {:ok, %ProviderStatus{smoke_ready: true}}}), do: true
  defp provider_ready?(_row), do: false
  defp unknown_auth?(%{result: {:ok, %ProviderStatus{authenticated: :unknown}}}), do: true
  defp unknown_auth?(_row), do: false

  defp json_value({:ok, value}), do: json_value(value)
  defp json_value({:error, value}), do: %{"error" => format_error(value)}
  defp json_value(%_{} = struct), do: struct |> Map.from_struct() |> json_value()
  defp json_value(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, json_value(value)} end)
  defp json_value(list) when is_list(list), do: Enum.map(list, &json_value/1)

  defp json_value(value)
       when is_atom(value) or is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value

  defp json_value(value), do: inspect(value, limit: 20, printable_limit: 1_000)

  defp scope(%{provider: nil}), do: "probe-only"
  defp scope(%{provider: provider}), do: "adapter:#{provider}"
  defp baseline(:latest), do: "latest"
  defp baseline(version), do: version
  defp answer(true), do: "yes"
  defp answer(false), do: "no"
  defp answer(:unknown), do: "unknown"
  defp answer(value), do: to_string(value)
  defp format_error({:error, error}), do: format_error(error)
  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error, limit: 10, printable_limit: 500)
end
