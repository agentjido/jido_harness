defmodule Mix.Tasks.JidoHarness.Query do
  @moduledoc """
  Sends an arbitrary prompt through one or more registered harness adapters.

      mix jido_harness.query codex "Explain this repository in one sentence."
      mix jido_harness.query amp,claude,codex "Reply with exactly: ready"
      mix jido_harness.query all "Reply with exactly: ready" --expect ready

  Queries run sequentially so an `all` check does not create an accidental
  burst of billable provider work. Every selected provider is attempted even
  when an earlier provider fails, and the task exits unsuccessfully after
  printing the complete matrix if any provider fails or returns empty output.

  Provider requests may consume paid API or subscription usage.
  """
  use Mix.Task

  alias Jido.Harness.{RunResult, RunInfo}

  @shortdoc "Send a prompt through registered harness adapters"
  @default_timeout_seconds 300

  @impl true
  def run(args) do
    {options, positional} = parse_args(args)

    if path = options[:env_file], do: Mix.Tasks.JidoHarness.Integration.load_env_file(path)

    Mix.Task.run("app.start")

    [selector | prompt_parts] = positional
    prompt = Enum.join(prompt_parts, " ")
    providers = select_providers(selector, Jido.Harness.providers())
    request = request(prompt, options)

    outcomes =
      Enum.map(providers, fn provider ->
        unless options[:json], do: Mix.shell().info("\n[#{provider}] starting query")
        outcome = query(provider, request, options)
        unless options[:json], do: print_outcome(outcome)
        outcome
      end)

    if options[:json], do: Mix.shell().info(Jason.encode!(outcomes, pretty: true))

    failures = Enum.reject(outcomes, & &1.ok)

    if failures != [] do
      Mix.raise("query failed: #{Enum.map_join(failures, ",", & &1.provider)}")
    end

    :ok
  end

  @doc false
  def parse_args(args) do
    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          cwd: :string,
          model: :string,
          provider_session_id: :string,
          timeout: :integer,
          idle_timeout: :integer,
          max_turns: :integer,
          expect: :string,
          env_file: :string,
          json: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid query options: #{inspect(invalid)}")

    case positional do
      [_provider, prompt | _rest] when is_binary(prompt) -> :ok
      _ -> Mix.raise("usage: mix jido_harness.query PROVIDER|all \"PROMPT\"")
    end

    validate_positive!(options, :timeout)
    validate_positive!(options, :idle_timeout)
    validate_positive!(options, :max_turns)

    {options, positional}
  end

  @doc false
  def select_providers("all", specs), do: Enum.map(specs, & &1.provider)

  def select_providers(selector, specs) when is_binary(selector) do
    available = Map.new(specs, &{Atom.to_string(&1.provider), &1.provider})

    names =
      selector
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    unknown = Enum.reject(names, &Map.has_key?(available, &1))

    if names == [], do: Mix.raise("provider selector must not be empty")

    if unknown != [] do
      choices = available |> Map.keys() |> Enum.sort() |> Enum.join(",")
      Mix.raise("unknown providers: #{Enum.join(unknown, ",")}; available: #{choices}")
    end

    Enum.map(names, &Map.fetch!(available, &1))
  end

  @doc false
  def query(provider, request, options) when is_atom(provider) and is_map(request) do
    started_at = System.monotonic_time(:millisecond)

    case Jido.Harness.start(provider, request) do
      {:ok, run_id} -> await_query(provider, run_id, started_at, options)
      {:error, error} -> failure(provider, nil, started_at, format_error(error))
    end
  end

  defp request(prompt, options) do
    timeout_ms = Keyword.get(options, :timeout, @default_timeout_seconds) * 1_000

    %{
      prompt: prompt,
      cwd: Path.expand(Keyword.get(options, :cwd, File.cwd!())),
      runtime_timeout_ms: timeout_ms,
      metadata: %{"source" => "mix jido_harness.query"}
    }
    |> put_optional(:idle_timeout_ms, seconds_to_ms(options[:idle_timeout]))
    |> put_optional(:model, options[:model])
    |> put_optional(:provider_session_id, options[:provider_session_id])
    |> put_optional(:max_turns, options[:max_turns])
  end

  defp await_query(provider, run_id, started_at, options) do
    timeout_ms = Keyword.get(options, :timeout, @default_timeout_seconds) * 1_000

    case Jido.Harness.await(run_id, timeout_ms + 15_000) do
      {:ok, %RunResult{} = result} ->
        result_outcome(result, started_at, options[:expect])

      {:error, error} ->
        cleanup_timed_out_run(run_id)
        failure(provider, run_id, started_at, "await failed: #{format_error(error)}")
    end
  end

  defp result_outcome(%RunResult{} = result, started_at, expected) do
    text = result.text || ""
    error = result_error(result, text, expected)

    %{
      ok: is_nil(error),
      provider: Atom.to_string(result.provider),
      run_id: result.run_id,
      provider_session_id: result.provider_session_id,
      status: Atom.to_string(result.status),
      text: text,
      text_truncated: result.text_truncated? || false,
      usage: result.usage || %{},
      duration_ms: elapsed(started_at),
      error: error
    }
  end

  defp result_error(%RunResult{status: :completed}, text, expected) do
    cond do
      String.trim(text) == "" -> "provider completed without a text response"
      is_binary(expected) and String.trim(text) != String.trim(expected) -> "response did not exactly match --expect"
      true -> nil
    end
  end

  defp result_error(%RunResult{status: status, error: error}, _text, _expected),
    do: "#{status}: #{format_error(error)}"

  defp failure(provider, run_id, started_at, error) do
    %{
      ok: false,
      provider: Atom.to_string(provider),
      run_id: run_id,
      provider_session_id: nil,
      status: "failed",
      text: "",
      text_truncated: false,
      usage: %{},
      duration_ms: elapsed(started_at),
      error: error
    }
  end

  defp print_outcome(outcome) do
    Mix.shell().info("[#{outcome.provider}] run_id=#{outcome.run_id || "not-started"} status=#{outcome.status}")

    if outcome.text != "", do: Mix.shell().info(outcome.text)
    if outcome.text_truncated, do: Mix.shell().error("[#{outcome.provider}] response shows only the retained text tail")
    if outcome.error, do: Mix.shell().error("[#{outcome.provider}] #{outcome.error}")
  end

  defp cleanup_timed_out_run(run_id) do
    case Jido.Harness.info(run_id) do
      {:ok, %RunInfo{} = info} ->
        unless RunInfo.terminal?(info), do: Jido.Harness.cancel(run_id)
        _ = Jido.Harness.await(run_id, 15_000)
        :ok

      _ ->
        :ok
    end
  end

  defp validate_positive!(options, key) do
    case options[key] do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      _ -> Mix.raise("--#{String.replace(Atom.to_string(key), "_", "-")} must be a positive integer")
    end
  end

  defp seconds_to_ms(nil), do: nil
  defp seconds_to_ms(seconds), do: seconds * 1_000
  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
  defp elapsed(started_at), do: System.monotonic_time(:millisecond) - started_at
  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(nil), do: "provider did not report an error"
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error, limit: 20, printable_limit: 1_000)
end
