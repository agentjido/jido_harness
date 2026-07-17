defmodule Mix.Tasks.JidoHarness.Check do
  @moduledoc """
  Checks registered provider readiness without sending an agent prompt.

      mix jido_harness.check
      mix jido_harness.check --providers codex,kimi --strict
      mix jido_harness.check --json

  The check reports installation, version compatibility, authentication status,
  and the adapter's installation recipe when a provider is unavailable.
  """
  use Mix.Task

  alias Jido.Harness.{AdapterSpec, ProviderStatus}

  @shortdoc "Check registered provider readiness"

  @impl true
  def run(args) do
    {options, rest, invalid} =
      OptionParser.parse(args,
        strict: [providers: :string, strict: :boolean, json: :boolean],
        aliases: [p: :providers]
      )

    if invalid != [] or rest != [] do
      Mix.raise("invalid check options: #{inspect(invalid ++ Enum.map(rest, &{&1, nil}))}")
    end

    Mix.Task.run("app.start")

    rows =
      options[:providers]
      |> select_providers(Jido.Harness.providers())
      |> Enum.map(fn spec -> %{spec: spec, result: safe_status(spec.provider)} end)

    if options[:json], do: print_json(rows), else: print_report(rows)
    if options[:strict], do: assert_ready!(rows)
    :ok
  end

  @doc false
  def select_providers(selector, specs) when selector in [nil, "", "all"], do: specs

  def select_providers(selector, specs) when is_binary(selector) do
    available = Map.new(specs, &{Atom.to_string(&1.provider), &1})
    names = selected_names(selector)
    unknown = Enum.reject(names, &Map.has_key?(available, &1))

    if unknown != [] do
      choices = available |> Map.keys() |> Enum.sort() |> Enum.join(",")
      Mix.raise("unknown providers: #{Enum.join(unknown, ",")}; available: #{choices}")
    end

    Enum.map(names, &Map.fetch!(available, &1))
  end

  defp selected_names(selector) do
    names =
      selector
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if names == [], do: Mix.raise("--providers must contain at least one name")
    names
  end

  defp safe_status(provider) do
    Jido.Harness.status(provider)
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp print_report(rows) do
    Mix.shell().info("provider    installed compatible auth     ready version")

    Enum.each(rows, fn
      %{spec: spec, result: {:ok, %ProviderStatus{} = status}} ->
        Mix.shell().info(
          Enum.join(
            [
              spec.provider |> Atom.to_string() |> String.pad_trailing(11),
              status.installed |> answer() |> String.pad_trailing(10),
              status.compatible |> answer() |> String.pad_trailing(11),
              status.authenticated |> answer() |> String.pad_trailing(8),
              status.smoke_ready |> answer() |> String.pad_trailing(5),
              status.version || "-"
            ],
            " "
          )
        )

        unless status.smoke_ready, do: print_install(spec)

      %{spec: spec, result: result} ->
        Mix.shell().error("#{spec.provider}: #{format_error(result)}")
        print_install(spec)
    end)

    if Enum.any?(rows, &unknown_auth?/1) do
      Mix.shell().info("Auth 'unknown' may indicate a cached CLI login; use jido_harness.chat for a live check.")
    end
  end

  defp print_install(%AdapterSpec{} = spec) do
    guidance = install_command(spec) || spec.docs_url || "see provider documentation"
    Mix.shell().info("  install #{spec.provider}: #{guidance}")
  end

  defp install_command(%AdapterSpec{install: %{npm: package, npm_args: args}})
       when is_binary(package) and is_list(args),
       do: Enum.join(["npm", "install", "--global"] ++ args ++ [package], " ")

  defp install_command(%AdapterSpec{install: %{npm: package}}) when is_binary(package),
    do: "npm install --global #{package}"

  defp install_command(%AdapterSpec{}), do: nil

  defp print_json(rows) do
    providers =
      Enum.map(rows, fn
        %{spec: spec, result: {:ok, %ProviderStatus{} = status}} ->
          %{
            provider: spec.provider,
            installed: status.installed,
            compatible: status.compatible,
            authenticated: status.authenticated,
            ready: status.smoke_ready,
            version: status.version,
            executable: status.executable
          }

        %{spec: spec, result: result} ->
          %{provider: spec.provider, error: format_error(result)}
      end)

    Mix.shell().info(Jason.encode!(%{providers: providers}, pretty: true))
  end

  defp assert_ready!(rows) do
    failures = rows |> Enum.reject(&ready?/1) |> Enum.map(& &1.spec.provider)
    if failures != [], do: Mix.raise("harness check failed: #{Enum.join(failures, ",")}")
  end

  defp ready?(%{result: {:ok, %ProviderStatus{smoke_ready: true}}}), do: true
  defp ready?(_row), do: false
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
