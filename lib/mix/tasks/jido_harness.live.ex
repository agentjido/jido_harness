defmodule Mix.Tasks.JidoHarness.Live do
  @moduledoc """
  Checks, installs, and live-tests Jido.Harness providers.

  Running the task without flags is a non-billable readiness check for every
  registered provider:

      mix jido_harness.live

  Installation and live requests are always explicit:

      mix jido_harness.live --providers codex,kimi --install
      mix jido_harness.live --providers codex --test --profile smoke

  Live profiles are delegated to `mix jido_harness.integration`, so they have
  the same strict-mode, environment-file, artifact, and watchdog behavior.
  """
  use Mix.Task

  alias Jido.Harness.{AdapterSpec, ProviderStatus}

  @shortdoc "Check, install, and live-test harness providers"
  @profiles ~w(smoke contract lifecycle)

  @impl true
  def run(args) do
    {options, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          providers: :string,
          profile: :string,
          strict: :boolean,
          env_file: :string,
          install: :boolean,
          test: :boolean
        ],
        aliases: [p: :providers]
      )

    if invalid != [] or rest != [] do
      Mix.raise("invalid live options: #{inspect(invalid ++ Enum.map(rest, &{&1, nil}))}")
    end

    profile = Keyword.get(options, :profile, "smoke")
    unless profile in @profiles, do: Mix.raise("invalid live profile: #{profile}")

    if path = options[:env_file], do: Mix.Tasks.JidoHarness.Integration.load_env_file(path)

    Mix.Task.run("app.start")

    specs = select_providers(options[:providers], Jido.Harness.providers())
    rows = probe_and_print(specs)

    rows =
      if options[:install] do
        install_unavailable(specs, rows)
        Mix.shell().info("\nReadiness after installation")
        probe_and_print(specs)
      else
        rows
      end

    print_install_guidance(rows)
    print_live_guidance(specs)

    if options[:strict] && not options[:test] do
      assert_ready!(rows)
    end

    if options[:test] do
      run_live_tests(specs, profile, options)
    else
      :ok
    end
  end

  @doc false
  def select_providers(selector, specs) when selector in [nil, "", "all"], do: specs

  def select_providers(selector, specs) when is_binary(selector) do
    by_name = Map.new(specs, &{Atom.to_string(&1.provider), &1})

    names =
      selector
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    unknown = Enum.reject(names, &Map.has_key?(by_name, &1))

    if names == [] do
      Mix.raise("--providers must contain at least one provider")
    end

    if unknown != [] do
      available = by_name |> Map.keys() |> Enum.sort() |> Enum.join(",")
      Mix.raise("unknown providers: #{Enum.join(unknown, ",")}; available: #{available}")
    end

    Enum.map(names, &Map.fetch!(by_name, &1))
  end

  @doc false
  def install_command(%AdapterSpec{install: %{npm: package, npm_args: args}})
      when is_binary(package) and is_list(args),
      do: Enum.join(["npm", "install", "--global"] ++ args ++ [package], " ")

  def install_command(%AdapterSpec{install: %{npm: package}}) when is_binary(package),
    do: "npm install --global #{package}"

  def install_command(%AdapterSpec{}), do: nil

  defp probe_and_print(specs) do
    Mix.shell().info("\nJido.Harness provider readiness")
    Mix.shell().info("provider    installed compatible auth     ready version")

    Enum.map(specs, fn spec ->
      result = safe_status(spec.provider)
      print_status(spec, result)
      %{spec: spec, result: result}
    end)
  end

  defp safe_status(provider) do
    Jido.Harness.status(provider)
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp print_status(spec, {:ok, %ProviderStatus{} = status}) do
    fields = [
      spec.provider |> Atom.to_string() |> String.pad_trailing(11),
      status.installed |> answer() |> String.pad_trailing(10),
      status.compatible |> answer() |> String.pad_trailing(11),
      status.authenticated |> answer() |> String.pad_trailing(8),
      status.smoke_ready |> answer() |> String.pad_trailing(5),
      status.version || "-"
    ]

    Mix.shell().info(Enum.join(fields, " "))
  end

  defp print_status(spec, result) do
    provider = spec.provider |> Atom.to_string() |> String.pad_trailing(11)
    Mix.shell().info("#{provider} error: #{format_error(result)}")
  end

  defp install_unavailable(specs, rows) do
    rows_by_provider = Map.new(rows, &{&1.spec.provider, &1})

    Enum.each(specs, fn spec ->
      row = Map.fetch!(rows_by_provider, spec.provider)

      if unavailable?(row) do
        case safe_status(spec.provider) do
          {:ok, %ProviderStatus{installed: true, compatible: true}} ->
            Mix.shell().info("#{spec.name} became available; skipping installation")

          _other ->
            install_provider(spec)
        end
      end
    end)
  end

  defp install_provider(spec) do
    case install_command(spec) do
      nil ->
        Mix.shell().error("#{spec.name} has no automatic installation recipe; see #{spec.docs_url || "provider docs"}")

      command ->
        Mix.shell().info("Installing #{spec.name} with #{command}")

        case Jido.Harness.install(spec.provider) do
          {:ok, _result} -> Mix.shell().info("Installed #{spec.name}")
          {:error, error} -> Mix.shell().error("Could not install #{spec.name}: #{format_error(error)}")
        end
    end
  end

  defp print_install_guidance(rows) do
    unavailable = Enum.filter(rows, &unavailable?/1)

    if unavailable != [] do
      Mix.shell().info("\nInstall or upgrade unavailable CLIs")

      Enum.each(unavailable, fn %{spec: spec} ->
        command = install_command(spec) || "No automatic recipe; follow the provider documentation"
        Mix.shell().info("  #{spec.provider}: #{command}")
        if spec.docs_url, do: Mix.shell().info("       #{spec.docs_url}")
      end)

      providers = unavailable |> Enum.map(& &1.spec.provider) |> Enum.join(",")
      Mix.shell().info("  Managed install: mix jido_harness.live --providers #{providers} --install")
    end

    if Enum.any?(rows, &unknown_auth?/1) do
      Mix.shell().info("\nAuth 'unknown' means no recognized API-key environment variable was set.")
      Mix.shell().info("Cached CLI login may still be valid; use a smoke test to verify it.")
    end
  end

  defp print_live_guidance(specs) do
    providers = specs |> Enum.map(& &1.provider) |> Enum.join(",")

    Mix.shell().info("\nLive testing (may contact providers and incur usage)")
    Mix.shell().info("  Smoke:     mix jido_harness.live --providers #{providers} --test --profile smoke")
    Mix.shell().info("  Contract:  mix jido_harness.live --providers #{providers} --test --profile contract")
    Mix.shell().info("  Lifecycle: mix jido_harness.live --providers #{providers} --test --profile lifecycle")
    Mix.shell().info("  Add --strict to fail instead of skipping unavailable providers.")
    Mix.shell().info("  Add --env-file /absolute/path/to/file to load missing KEY=value credentials.")
  end

  defp run_live_tests(specs, profile, options) do
    providers = specs |> Enum.map(& &1.provider) |> Enum.join(",")
    args = ["--providers", providers, "--profile", profile]
    args = if options[:strict], do: args ++ ["--strict"], else: args

    Mix.shell().info("\nStarting #{profile} live tests for #{providers}")
    Mix.Task.reenable("jido_harness.integration")
    Mix.Task.run("jido_harness.integration", args)
  end

  defp assert_ready!(rows) do
    unavailable = Enum.filter(rows, &unavailable?/1)

    if unavailable != [] do
      names = unavailable |> Enum.map(& &1.spec.provider) |> Enum.join(",")
      Mix.raise("providers are not ready: #{names}")
    end
  end

  defp unavailable?(%{result: {:ok, %ProviderStatus{smoke_ready: true}}}), do: false
  defp unavailable?(_row), do: true

  defp unknown_auth?(%{result: {:ok, %ProviderStatus{authenticated: :unknown}}}), do: true
  defp unknown_auth?(_row), do: false

  defp answer(true), do: "yes"
  defp answer(false), do: "no"
  defp answer(:unknown), do: "unknown"
  defp answer(value), do: to_string(value)

  defp format_error({:error, error}), do: format_error(error)
  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error, limit: 10, printable_limit: 500)
end
