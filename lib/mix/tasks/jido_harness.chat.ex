defmodule Mix.Tasks.JidoHarness.Chat do
  @moduledoc """
  Sends one live prompt through one registered provider.

      mix jido_harness.chat codex
      mix jido_harness.chat codex "Explain this repository in one sentence."
      mix jido_harness.chat codex --timeout 120 --json

  With no prompt, the task asks for exactly `ready`. Each invocation starts one
  finite harness run and may consume paid API or subscription usage.
  """
  use Mix.Task

  alias Jido.Harness.{RunInfo, RunResult}

  @shortdoc "Send one live prompt through a registered provider"
  @default_prompt "Reply with exactly: ready"
  @default_timeout_seconds 300

  @impl true
  def run(args) do
    {options, provider_name, prompt} = parse_args(args)
    Mix.Task.run("app.start")

    provider = select_provider(provider_name, Jido.Harness.providers())
    outcome = query(provider, prompt, options[:timeout])

    if options[:json], do: print_json(outcome), else: print_outcome(outcome)

    unless outcome.ok, do: Mix.raise("chat failed: #{outcome.provider}")
    :ok
  end

  @doc false
  def parse_args(args) do
    {options, positional, invalid} =
      OptionParser.parse(args, strict: [timeout: :integer, json: :boolean])

    if invalid != [], do: Mix.raise("invalid chat options: #{inspect(invalid)}")

    {selector, prompt_parts} =
      case positional do
        [selector | prompt_parts] -> {selector, prompt_parts}
        _ -> Mix.raise("usage: mix jido_harness.chat PROVIDER [\"PROMPT\"] [--timeout SECONDS] [--json]")
      end

    timeout = Keyword.get(options, :timeout, @default_timeout_seconds)
    unless is_integer(timeout) and timeout > 0, do: Mix.raise("--timeout must be a positive integer")

    prompt = if prompt_parts == [], do: @default_prompt, else: Enum.join(prompt_parts, " ")
    {Keyword.put(options, :timeout, timeout), selector, prompt}
  end

  @doc false
  def select_provider(name, specs) when is_binary(name) do
    case Enum.find(specs, &(Atom.to_string(&1.provider) == name)) do
      nil ->
        choices = specs |> Enum.map(& &1.provider) |> Enum.sort() |> Enum.join(",")
        Mix.raise("unknown provider: #{name}; available: #{choices}")

      spec ->
        spec.provider
    end
  end

  defp query(provider, prompt, timeout_seconds) do
    timeout_ms = timeout_seconds * 1_000
    request = %{prompt: prompt, cwd: File.cwd!(), runtime_timeout_ms: timeout_ms}

    case Jido.Harness.start(provider, request) do
      {:ok, run_id} -> await_result(provider, run_id, timeout_ms)
      {:error, error} -> failure(provider, nil, error)
    end
  end

  defp await_result(provider, run_id, timeout_ms) do
    case Jido.Harness.await(run_id, timeout_ms + 15_000) do
      {:ok, %RunResult{status: :completed, text: text} = result} when is_binary(text) and text != "" ->
        %{
          ok: true,
          provider: Atom.to_string(provider),
          run_id: run_id,
          status: Atom.to_string(result.status),
          text: text,
          error: nil
        }

      {:ok, %RunResult{} = result} ->
        failure(provider, run_id, result.error || "provider completed without text", result.status)

      {:error, error} ->
        cancel_if_running(run_id)
        failure(provider, run_id, error)
    end
  end

  defp failure(provider, run_id, error, status \\ :failed) do
    %{
      ok: false,
      provider: Atom.to_string(provider),
      run_id: run_id,
      status: Atom.to_string(status),
      text: "",
      error: format_error(error)
    }
  end

  defp cancel_if_running(run_id) do
    case Jido.Harness.info(run_id) do
      {:ok, %RunInfo{} = info} -> unless RunInfo.terminal?(info), do: Jido.Harness.cancel(run_id)
      _ -> :ok
    end
  end

  defp print_outcome(%{ok: true} = outcome) do
    Mix.shell().info("[#{outcome.provider}] ok run_id=#{outcome.run_id}")
    Mix.shell().info(outcome.text)
  end

  defp print_outcome(outcome) do
    Mix.shell().error("[#{outcome.provider}] #{outcome.status}: #{outcome.error}")
  end

  defp print_json(outcome), do: Mix.shell().info(Jason.encode!(outcome, pretty: true))
  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(nil), do: "provider did not report an error"
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error, limit: 20, printable_limit: 1_000)
end
