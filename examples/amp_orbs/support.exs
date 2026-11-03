Mix.install([
  {:jido_harness, path: Path.expand("../..", __DIR__)}
])

defmodule JidoHarnessAmpExamples do
  @moduledoc false

  @default_project "agentjido/req_llm"
  @default_repo "agentjido/req_llm"

  def load_dotenv do
    dotenv_path = Path.expand("../../.env", __DIR__)

    if File.regular?(dotenv_path) do
      dotenv_path
      |> File.stream!()
      |> Enum.each(&put_dotenv_entry/1)
    end
  end

  def configure_defaults do
    put_default("JIDO_HARNESS_AMP_PROJECT", @default_project)
    put_default("JIDO_HARNESS_AMP_ORB_SIZE", "a1.medium")
    put_default("JIDO_HARNESS_AMP_MODE", "high")
    put_default("JIDO_HARNESS_AMP_VISIBILITY", "private")
    put_default("JIDO_HARNESS_AMP_LABELS", "req-llm,managed-by-jido-harness")
  end

  def amp_project, do: System.get_env("JIDO_HARNESS_AMP_PROJECT", @default_project)
  def github_repo, do: System.get_env("REQ_LLM_GITHUB_REPO", @default_repo)

  def require_amp_token! do
    case System.get_env("AMP_API_KEY") do
      "sgamp_" <> suffix -> if String.trim(suffix) == "", do: missing_amp_token!(), else: :ok
      _other -> missing_amp_token!()
    end
  end

  def pr!(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _other -> abort!("PR number must be a positive integer.")
    end
  end

  def positive_integer!(value, name) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _other -> abort!("#{name} must be a positive integer.")
    end
  end

  def github_pr!(number) do
    fields = "number,title,url,baseRefName,headRefName,headRefOid,author,state,isDraft,mergeStateStatus"

    case System.cmd(
           "gh",
           ["pr", "view", Integer.to_string(number), "--repo", github_repo(), "--json", fields],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, pr} -> pr
          {:error, reason} -> abort!("GitHub returned invalid JSON: #{inspect(reason)}")
        end

      {output, status} ->
        abort!("gh pr view failed with status #{status}:\n#{String.trim(output)}")
    end
  rescue
    error in ErlangError -> abort!("Could not run gh: #{Exception.message(error)}")
  end

  def result!({:ok, value}), do: value
  def result!(:ok), do: :ok

  def result!({:error, error}) do
    message = if is_exception(error), do: Exception.message(error), else: inspect(error)
    abort!(message)
  end

  def print_json(value) do
    value
    |> json_value()
    |> Jason.encode!(pretty: true)
    |> IO.puts()
  end

  def abort!(message) do
    IO.puts(:stderr, "error: #{message}")
    System.halt(1)
  end

  def usage!(text) do
    IO.puts(:stderr, text)
    System.halt(64)
  end

  defp put_default(name, value) do
    if is_nil(System.get_env(name)), do: System.put_env(name, value)
  end

  defp missing_amp_token!, do: abort!("AMP_API_KEY is required. Create an Amp access token that starts with sgamp_.")

  defp put_dotenv_entry(line) do
    case String.trim(line) do
      "" -> :ok
      "#" <> _rest -> :ok
      "export " <> entry -> put_dotenv_value(entry)
      entry -> put_dotenv_value(entry)
    end
  end

  defp put_dotenv_value(entry) do
    case String.split(entry, "=", parts: 2) do
      [name, value] ->
        name = String.trim(name)

        if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, name) and is_nil(System.get_env(name)) do
          System.put_env(name, dotenv_value(value))
        end

      _other ->
        :ok
    end
  end

  defp dotenv_value(value) do
    value = String.trim(value)

    case value do
      <<quote, rest::binary>> when quote in [?", ?'] -> String.trim_trailing(rest, <<quote>>)
      _other -> value
    end
  end

  defp json_value(%_module{} = value), do: value |> Map.from_struct() |> json_value()
  defp json_value(value) when is_map(value), do: Map.new(value, fn {key, item} -> {key, json_value(item)} end)
  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value), do: value
end

JidoHarnessAmpExamples.load_dotenv()
JidoHarnessAmpExamples.configure_defaults()
