defmodule Mix.Tasks.JidoHarness.Integration do
  @moduledoc "Runs opt-in Jido.Harness provider integration contracts."
  use Mix.Task

  @shortdoc "Run harness smoke, contract, lifecycle, or soak tests"

  @impl true
  def run(args) do
    {options, _rest, invalid} =
      OptionParser.parse(args,
        strict: [providers: :string, profile: :string, strict: :boolean, env_file: :string],
        aliases: [p: :providers]
      )

    if invalid != [], do: Mix.raise("invalid integration options: #{inspect(invalid)}")

    profile = Keyword.get(options, :profile, "contract")
    unless profile in ["smoke", "contract", "lifecycle", "soak"], do: Mix.raise("invalid profile: #{profile}")

    if path = options[:env_file], do: load_env_file(path)
    if providers = options[:providers], do: System.put_env("JIDO_HARNESS_INTEGRATION_PROVIDERS", providers)
    System.put_env("JIDO_HARNESS_INTEGRATION_PROFILE", profile)
    if options[:strict], do: System.put_env("JIDO_HARNESS_INTEGRATION_STRICT", "true")

    include = if profile == "soak", do: "soak", else: "integration"
    Mix.Task.run("test", ["--include", include, "--timeout", "7200000"])
  end

  defp load_env_file(path) do
    path
    |> File.stream!(:line, [])
    |> Enum.each(fn line ->
      line = String.trim(line)

      if line != "" and not String.starts_with?(line, "#") do
        case String.split(line, "=", parts: 2) do
          [key, value] -> if is_nil(System.get_env(key)), do: System.put_env(key, strip_quotes(value))
          _ -> Mix.raise("invalid env-file line in #{path}")
        end
      end
    end)
  end

  defp strip_quotes(value) do
    value = String.trim(value)

    if (String.starts_with?(value, "\"") and String.ends_with?(value, "\"")) or
         (String.starts_with?(value, "'") and String.ends_with?(value, "'")) do
      String.slice(value, 1, max(0, String.length(value) - 2))
    else
      value
    end
  end
end
