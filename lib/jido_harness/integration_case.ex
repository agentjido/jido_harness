defmodule Jido.Harness.IntegrationCase do
  @moduledoc """
  Opt-in ExUnit contract and lifecycle tests for harness providers.

      use Jido.Harness.IntegrationCase, provider: :codex
      harness_contract_tests()

  The generated tests are tagged `:integration`. This module never starts
  ExUnit or executes a provider test during normal package use.
  """

  @watchdog_ms 7_200_000
  @default_live_soak_duration_ms 600_000
  @default_live_soak_interval_ms 60_000
  @default_live_soak_turn_timeout_ms 600_000
  @artifact_root "jido_harness_integration_failures"
  @credential_env_names [
    "AI_GATEWAY_API_KEY",
    "AMP_API_KEY",
    "ANT_LING_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_OAUTH_TOKEN",
    "AWS_ACCESS_KEY_ID",
    "AWS_BEARER_TOKEN_BEDROCK",
    "AWS_SECRET_ACCESS_KEY",
    "AZURE_OPENAI_API_KEY",
    "CEREBRAS_API_KEY",
    "CLAUDE_CODE_API_KEY",
    "CLOUDFLARE_API_KEY",
    "CODEX_API_KEY",
    "DEEPSEEK_API_KEY",
    "FIREWORKS_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "GROQ_API_KEY",
    "HF_TOKEN",
    "KIMI_API_KEY",
    "KIMI_MODEL_API_KEY",
    "MINIMAX_API_KEY",
    "MINIMAX_CN_API_KEY",
    "MISTRAL_API_KEY",
    "MOONSHOT_API_KEY",
    "NVIDIA_API_KEY",
    "OPENAI_API_KEY",
    "OPENCODE_API_KEY",
    "OPENROUTER_API_KEY",
    "RADIUS_API_KEY",
    "TOGETHER_API_KEY",
    "XAI_API_KEY",
    "XIAOMI_API_KEY",
    "XIAOMI_TOKEN_PLAN_AMS_API_KEY",
    "XIAOMI_TOKEN_PLAN_CN_API_KEY",
    "XIAOMI_TOKEN_PLAN_SGP_API_KEY",
    "ZAI_API_KEY",
    "ZAI_CODING_CN_API_KEY"
  ]

  defmacro __using__(options) do
    provider = Keyword.fetch!(options, :provider)
    async? = profile() == :soak

    quote do
      use ExUnit.Case, async: unquote(async?)
      import Jido.Harness.IntegrationCase, only: [harness_contract_tests: 0]
      @jido_harness_provider unquote(provider)
      @moduletag :integration
      @moduletag timeout: unquote(@watchdog_ms)

      setup do
        baseline = Jido.Harness.IntegrationCase.cleanup_baseline()
        on_exit(fn -> Jido.Harness.IntegrationCase.cleanup_since(@jido_harness_provider, baseline) end)
        :ok
      end
    end
  end

  defmacro harness_contract_tests do
    quote do
      @tag skip: Jido.Harness.IntegrationCase.skip_reason(@jido_harness_provider, :status)
      test "#{@jido_harness_provider} exposes a valid adapter and status contract" do
        provider = @jido_harness_provider
        assert {:ok, spec} = Jido.Harness.Registry.spec(provider)
        assert spec.provider == provider
        assert {:ok, status} = Jido.Harness.status(provider)
        assert status.provider == provider
        assert status.authenticated in [true, false, :unknown]
      end

      @tag skip: Jido.Harness.IntegrationCase.skip_reason(@jido_harness_provider, :smoke)
      test "#{@jido_harness_provider} smoke, event, replay, and result contract" do
        provider = @jido_harness_provider

        Jido.Harness.IntegrationCase.with_ready_provider(provider, fn spec ->
          request =
            %{prompt: "Reply with exactly: harness-ok", runtime_timeout_ms: 300_000}
            |> Jido.Harness.IntegrationCase.limit_turns(spec)

          case Jido.Harness.IntegrationCase.run!(provider, request, await_timeout: 360_000) do
            nil ->
              :ok

            result ->
              Jido.Harness.IntegrationCase.verify!(provider, result, fn ->
                assert result.status == :completed
                assert result.run_id
                assert is_map(result.usage)
                assert Enum.all?(result.events, &match?(%Jido.Harness.Event{}, &1))
                assert Enum.count(result.events, &Jido.Harness.Event.terminal?/1) == 1
                assert result.events == Enum.sort_by(result.events, & &1.sequence)

                assert {:ok, replayed} = Jido.Harness.Run.replay(result.run_id, limit: 10_000)
                assert Enum.map(replayed, & &1.sequence) == Enum.map(result.events, & &1.sequence)

                assert {:ok, reattached} = Jido.Harness.Run.stream(result.run_id, poll_interval_ms: 10)
                assert Enum.map(Enum.to_list(reattached), & &1.sequence) == Enum.map(replayed, & &1.sequence)
              end)
          end
        end)
      end

      @tag skip: Jido.Harness.IntegrationCase.skip_reason(@jido_harness_provider, :contract)
      test "#{@jido_harness_provider} run survives its starting caller" do
        provider = @jido_harness_provider

        Jido.Harness.IntegrationCase.with_ready_provider(provider, fn spec ->
          request = %{prompt: "Reply with exactly: detached-ok"} |> Jido.Harness.IntegrationCase.limit_turns(spec)
          parent = self()

          {pid, monitor} =
            spawn_monitor(fn ->
              send(parent, {:started, Jido.Harness.Run.start(provider, request)})
            end)

          assert_receive {:started, {:ok, run_id}}, 10_000
          assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 10_000

          result = Jido.Harness.IntegrationCase.await!(provider, run_id, 600_000)
          Jido.Harness.IntegrationCase.verify!(provider, result, fn -> assert result.status == :completed end)
        end)
      end

      @tag skip: Jido.Harness.IntegrationCase.skip_reason(@jido_harness_provider, :lifecycle)
      test "#{@jido_harness_provider} cancellation is terminal and cleans up" do
        provider = @jido_harness_provider

        Jido.Harness.IntegrationCase.with_ready_provider(provider, fn _spec ->
          {:ok, run_id} =
            Jido.Harness.Run.start(provider, %{
              prompt: "Wait for further instructions before completing.",
              runtime_timeout_ms: 300_000
            })

          assert :ok = Jido.Harness.Run.cancel(run_id)
          result = Jido.Harness.IntegrationCase.await!(provider, run_id, 60_000)

          Jido.Harness.IntegrationCase.verify!(provider, result, fn ->
            assert result.status == :cancelled
            assert Enum.count(result.events, &Jido.Harness.Event.terminal?/1) == 1
          end)
        end)
      end

      @tag skip: Jido.Harness.IntegrationCase.skip_reason(@jido_harness_provider, :lifecycle)
      test "#{@jido_harness_provider} resumes a provider session when supported" do
        provider = @jido_harness_provider

        Jido.Harness.IntegrationCase.with_ready_provider(provider, fn spec ->
          if spec.capabilities.resume? do
            first =
              %{prompt: "Reply with exactly: first", runtime_timeout_ms: 300_000}
              |> Jido.Harness.IntegrationCase.limit_turns(spec)
              |> then(&Jido.Harness.IntegrationCase.run!(provider, &1, await_timeout: 360_000))

            if first && is_binary(first.provider_session_id) do
              resumed =
                %{
                  prompt: "Reply with exactly: resumed",
                  provider_session_id: first.provider_session_id,
                  runtime_timeout_ms: 300_000
                }
                |> Jido.Harness.IntegrationCase.limit_turns(spec)
                |> then(&Jido.Harness.IntegrationCase.run!(provider, &1, await_timeout: 360_000))

              if resumed do
                Jido.Harness.IntegrationCase.verify!(provider, resumed, fn ->
                  assert resumed.status == :completed
                  assert resumed.provider_session_id
                end)
              end
            else
              if first, do: Jido.Harness.IntegrationCase.unavailable!(provider, :provider_did_not_return_session_id)
            end
          end
        end)
      end

      @tag skip: Jido.Harness.IntegrationCase.skip_reason(@jido_harness_provider, :interactive)
      test "#{@jido_harness_provider} preserves context across two interactive turns" do
        provider = @jido_harness_provider

        Jido.Harness.IntegrationCase.with_ready_provider(provider, fn _spec ->
          token = "harness-#{System.unique_integer([:positive])}"
          {:ok, session_id} = Jido.Harness.Session.start(provider, %{})

          try do
            assert {:ok, %{state: :idle}} =
                     Jido.Harness.IntegrationCase.await_session_ready(provider, session_id, 60_000)

            {:ok, first_id} =
              Jido.Harness.Session.send_message(
                session_id,
                "Remember the token #{token}. Reply with exactly: first-ok"
              )

            assert {:ok, first} = Jido.Harness.Session.await(session_id, first_id, 600_000)
            assert first.status == :completed

            {:ok, second_id} =
              Jido.Harness.Session.send_message(
                session_id,
                "Reply with only the token I asked you to remember."
              )

            assert {:ok, second} = Jido.Harness.Session.await(session_id, second_id, 600_000)
            assert second.status == :completed
            assert second.text =~ token
          after
            Jido.Harness.Session.close(session_id)
          end
        end)
      end

      @tag skip: Jido.Harness.IntegrationCase.skip_reason(@jido_harness_provider, :soak)
      test "#{@jido_harness_provider} keeps one live ACP session healthy under soak" do
        provider = @jido_harness_provider

        Jido.Harness.IntegrationCase.with_ready_provider(provider, fn _spec ->
          case Jido.Harness.IntegrationCase.live_soak!(provider) do
            nil ->
              :ok

            summary ->
              assert summary.turns > 0
              assert summary.provider_session_id
              assert summary.protocol == :acp
          end
        end)
      end
    end
  end

  @doc false
  def selected?(provider) do
    case System.get_env("JIDO_HARNESS_INTEGRATION_PROVIDERS") do
      nil -> true
      "" -> true
      value -> Atom.to_string(provider) in String.split(value, ",", trim: true)
    end
  end

  @doc false
  def profile do
    case System.get_env("JIDO_HARNESS_INTEGRATION_PROFILE", "contract") do
      "smoke" -> :smoke
      "lifecycle" -> :lifecycle
      "soak" -> :soak
      "interactive" -> :interactive
      _ -> :contract
    end
  end

  @doc false
  def skip_reason(provider, kind) do
    cond do
      not selected?(provider) ->
        "provider not selected"

      kind == :contract and profile() not in [:contract, :lifecycle] ->
        "contract profile not selected"

      kind == :lifecycle and profile() != :lifecycle ->
        "lifecycle profile not selected"

      kind == :interactive and profile() != :interactive ->
        "interactive profile not selected"

      kind == :soak and profile() != :soak ->
        "live soak profile not selected"

      strict?() ->
        false

      true ->
        executable_skip_reason(provider)
    end
  end

  @doc false
  def limit_turns(request, spec) do
    if :max_turns in spec.normalized_options, do: Map.put(request, :max_turns, 1), else: request
  end

  @doc false
  def with_ready_provider(provider, function) do
    case Jido.Harness.status(provider) do
      {:ok, status} ->
        if Jido.Harness.ProviderStatus.ready?(status) do
          {:ok, spec} = Jido.Harness.Registry.spec(provider)
          function.(spec)
        else
          unavailable!(provider, status)
        end

      {:error, reason} ->
        unavailable!(provider, reason)
    end
  end

  @doc false
  def run!(provider, request, options) do
    case Jido.Harness.run(provider, request, options) do
      {:ok, %{status: :failed, error: error} = result} ->
        if not strict?() and auth_failure?(error) do
          unavailable!(provider, :credentials_unavailable)
          nil
        else
          result
        end

      {:ok, result} ->
        result

      {:error, reason} ->
        if not strict?() and auth_failure?(reason) do
          unavailable!(provider, :credentials_unavailable)
          nil
        else
          failure!(provider, nil, {:run_failed, reason})
        end
    end
  end

  @doc false
  def cleanup_baseline do
    %{
      runs: Jido.Harness.Run.list() |> Enum.map(& &1.run_id) |> MapSet.new(),
      sessions: Jido.Harness.Session.list() |> Enum.map(& &1.session_id) |> MapSet.new(),
      processes: Jido.Harness.Process.list() |> Enum.map(& &1.process_id) |> MapSet.new()
    }
  end

  @doc false
  def cleanup_since(provider, baseline) do
    Jido.Harness.Session.list(providers: [provider])
    |> Enum.reject(&MapSet.member?(baseline.sessions, &1.session_id))
    |> Enum.each(fn info ->
      unless Jido.Harness.SessionInfo.terminal?(info), do: Jido.Harness.Session.close(info.session_id)
      _ = Jido.Harness.Session.prune(info.session_id)
    end)

    Jido.Harness.Run.list(providers: [provider])
    |> Enum.reject(&MapSet.member?(baseline.runs, &1.run_id))
    |> Enum.each(fn info ->
      unless Jido.Harness.RunInfo.terminal?(info), do: Jido.Harness.Run.cancel(info.run_id)
      _ = Jido.Harness.Run.await(info.run_id, 15_000)
      _ = Jido.Harness.Run.prune(info.run_id)
    end)

    Jido.Harness.Process.list()
    |> Enum.reject(&MapSet.member?(baseline.processes, &1.process_id))
    |> Enum.filter(&(Map.get(&1.metadata, :provider) == provider or Map.get(&1.metadata, "provider") == provider))
    |> Enum.each(fn info ->
      unless Jido.Harness.ProcessInfo.terminal?(info), do: Jido.Harness.Process.cancel(info.process_id)
      _ = Jido.Harness.Process.await(info.process_id, 15_000)
      _ = Jido.Harness.Process.prune(info.process_id)
    end)

    :ok
  end

  @doc false
  def await!(provider, run_id, timeout) do
    case Jido.Harness.Run.await(run_id, timeout) do
      {:ok, result} -> result
      {:error, reason} -> failure!(provider, run_id, {:await_failed, reason})
    end
  end

  @doc false
  def await_session_ready(provider, session_id, timeout) do
    started = System.monotonic_time(:millisecond)

    case do_await_session_ready(session_id, timeout, started) do
      {:ok, _info} = result -> result
      {:error, reason} -> failure!(provider, nil, {:session_open_failed, reason})
    end
  end

  @doc false
  def live_soak!(provider) do
    duration_ms = integer_env!(provider, "JIDO_HARNESS_LIVE_SOAK_DURATION_MS", @default_live_soak_duration_ms, 1)
    interval_ms = integer_env!(provider, "JIDO_HARNESS_LIVE_SOAK_INTERVAL_MS", @default_live_soak_interval_ms, 0)

    turn_timeout_ms =
      integer_env!(
        provider,
        "JIDO_HARNESS_LIVE_SOAK_TURN_TIMEOUT_MS",
        @default_live_soak_turn_timeout_ms,
        1
      )

    max_turns = optional_integer_env!(provider, "JIDO_HARNESS_LIVE_SOAK_MAX_TURNS", 1)

    request = %{
      metadata: %{integration_profile: "live_acp_soak"},
      session_idle_timeout_ms: :infinity,
      turn_runtime_timeout_ms: turn_timeout_ms,
      turn_idle_timeout_ms: turn_timeout_ms,
      approval_timeout_ms: min(turn_timeout_ms, 60_000)
    }

    case Jido.Harness.Session.start(provider, request) do
      {:ok, session_id} ->
        live_soak_session(provider, session_id, duration_ms, interval_ms, turn_timeout_ms, max_turns)

      {:error, reason} ->
        live_unavailable_or_fail(provider, {:session_start_failed, reason})
    end
  end

  @doc false
  def verify!(provider, result, function) do
    function.()
  rescue
    exception ->
      _path = write_failure_artifacts(provider, result.run_id, exception)
      reraise exception, __STACKTRACE__
  end

  @doc false
  def unavailable!(provider, status) do
    if strict?() do
      failure!(provider, nil, {:unavailable, status})
    else
      IO.puts("Skipping unavailable #{provider} integration: #{inspect(status)}")
      :ok
    end
  end

  @doc false
  def failure!(provider, run_id, reason) do
    path = write_failure_artifacts(provider, run_id, reason)
    raise ExUnit.AssertionError, message: "#{provider} integration failed; redacted artifacts: #{path}"
  end

  @doc false
  def write_failure_artifacts(provider, run_id, reason) do
    id = run_id || "no-run"

    dir =
      Path.join([
        System.tmp_dir!(),
        @artifact_root,
        Atom.to_string(provider),
        "#{id}-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    info = run_info(run_id)
    status = redacted_status(provider)

    write_json(Path.join(dir, "status.json"), %{
      provider: provider,
      failure_type: failure_type(reason),
      status: status
    })

    write_json(Path.join(dir, "run.json"), %{
      run_id: run_id,
      journal_location: if(info, do: info.journal_dir),
      state: if(info, do: info.state)
    })

    write_events(Path.join(dir, "events.jsonl"), replay_events(run_id))
    dir
  rescue
    _error -> Path.join(System.tmp_dir!(), @artifact_root)
  end

  defp executable_skip_reason(provider) do
    with {:ok, spec} <- Jido.Harness.Registry.spec(provider),
         config <- Jido.Harness.Registry.provider_config(provider),
         executable <- Map.get(config, :cli_path) || Map.get(config, "cli_path") || spec.executable,
         {:ok, _path} <- Jido.Harness.ProcessSpec.resolve_executable(executable) do
      false
    else
      _reason -> "provider executable is unavailable"
    end
  end

  defp live_soak_session(provider, session_id, duration_ms, interval_ms, turn_timeout_ms, max_turns) do
    started = System.monotonic_time(:millisecond)

    try do
      case do_await_session_ready(session_id, turn_timeout_ms, started) do
        {:ok, _info} ->
          process_identity = live_agent_process!(provider, session_id)
          deadline = System.monotonic_time(:millisecond) + duration_ms

          live_soak_turns(
            provider,
            session_id,
            process_identity,
            deadline,
            interval_ms,
            turn_timeout_ms,
            max_turns,
            0,
            nil
          )

        {:error, reason} ->
          live_unavailable_or_fail(provider, {:session_open_failed, reason})
      end
    after
      _ = Jido.Harness.Session.close(session_id)
    end
  end

  defp live_soak_turns(
         provider,
         session_id,
         process_identity,
         deadline,
         interval_ms,
         turn_timeout_ms,
         max_turns,
         completed_turns,
         provider_session_id
       ) do
    number = completed_turns + 1
    token = "harness-live-soak-#{provider}-#{number}-#{System.unique_integer([:positive])}"

    with {:ok, turn_id} <- Jido.Harness.Session.send_message(session_id, "Reply with exactly: #{token}"),
         {:ok, result} <- Jido.Harness.Session.await(session_id, turn_id, turn_timeout_ms) do
      case validate_live_soak_turn(provider, process_identity, result, token, provider_session_id) do
        {:ok, provider_session_id} ->
          IO.puts("Live ACP soak #{provider}: turn #{number} completed")

          if live_soak_complete?(number, max_turns, deadline) do
            live_soak_summary!(provider, session_id, number, provider_session_id)
          else
            remaining = max(deadline - System.monotonic_time(:millisecond), 0)
            Process.sleep(min(interval_ms, remaining))

            if System.monotonic_time(:millisecond) >= deadline do
              live_soak_summary!(provider, session_id, number, provider_session_id)
            else
              live_soak_turns(
                provider,
                session_id,
                process_identity,
                deadline,
                interval_ms,
                turn_timeout_ms,
                max_turns,
                number,
                provider_session_id
              )
            end
          end

        :unavailable ->
          nil
      end
    else
      {:error, reason} -> live_unavailable_or_fail(provider, {:live_soak_turn_failed, reason})
    end
  end

  defp validate_live_soak_turn(provider, process_identity, result, token, expected_session_id) do
    cond do
      result.status == :failed and not strict?() and auth_failure?(result.error) ->
        unavailable!(provider, :credentials_unavailable)
        :unavailable

      result.status != :completed ->
        failure!(provider, nil, {:live_soak_turn_status, result.status, result.error})

      not is_binary(result.text) or not String.contains?(result.text, token) ->
        failure!(provider, nil, {:live_soak_response_mismatch, result.text})

      not is_binary(result.provider_session_id) ->
        failure!(provider, nil, :live_soak_session_id_missing)

      is_binary(expected_session_id) and result.provider_session_id != expected_session_id ->
        failure!(provider, nil, :live_soak_session_id_changed)

      not live_agent_running?(process_identity) ->
        failure!(provider, nil, :live_soak_agent_process_stopped)

      true ->
        {:ok, expected_session_id || result.provider_session_id}
    end
  end

  defp live_soak_complete?(turns, max_turns, deadline) do
    (is_integer(max_turns) and turns >= max_turns) or System.monotonic_time(:millisecond) >= deadline
  end

  defp live_soak_summary!(provider, session_id, turns, provider_session_id) do
    case Jido.Harness.Session.replay(session_id, limit: 10_000) do
      {:ok, events} ->
        sequences = Enum.map(events, & &1.sequence)
        completed = Enum.count(events, &(&1.type == :turn_completed))
        acp_ready? = Enum.any?(events, &match?(%{type: :session_ready, payload: %{"protocol" => "acp"}}, &1))

        cond do
          sequences != Enum.sort(sequences) -> failure!(provider, nil, :live_soak_event_order)
          completed < turns -> failure!(provider, nil, :live_soak_missing_turn_events)
          not acp_ready? -> failure!(provider, nil, :live_soak_not_acp)
          true -> %{provider: provider, protocol: :acp, turns: turns, provider_session_id: provider_session_id}
        end

      {:error, reason} ->
        failure!(provider, nil, {:live_soak_replay_failed, reason})
    end
  end

  defp live_agent_process!(provider, session_id) do
    case Enum.find(Jido.Harness.Process.list(), fn info ->
           Map.get(info.metadata, :session_id) == session_id or Map.get(info.metadata, "session_id") == session_id
         end) do
      nil -> failure!(provider, nil, :live_soak_agent_process_missing)
      info -> %{process_id: info.process_id, os_pid: info.os_pid, started_at: info.started_at}
    end
  end

  defp live_agent_running?(identity) do
    case Jido.Harness.Process.info(identity.process_id) do
      {:ok, info} ->
        info.state == :running and info.os_pid == identity.os_pid and info.started_at == identity.started_at

      _error ->
        false
    end
  end

  defp live_unavailable_or_fail(provider, reason) do
    if not strict?() and auth_failure?(reason) do
      unavailable!(provider, :credentials_unavailable)
      nil
    else
      failure!(provider, nil, reason)
    end
  end

  defp integer_env!(provider, name, default, minimum) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> parse_integer_env!(provider, name, value, minimum)
    end
  end

  defp optional_integer_env!(provider, name, minimum) do
    case System.get_env(name) do
      nil -> :infinity
      "" -> :infinity
      value -> parse_integer_env!(provider, name, value, minimum)
    end
  end

  defp parse_integer_env!(provider, name, value, minimum) do
    case Integer.parse(value) do
      {number, ""} when number >= minimum -> number
      _invalid -> failure!(provider, nil, {:invalid_integration_environment, name})
    end
  end

  defp do_await_session_ready(session_id, timeout, started) do
    case Jido.Harness.Session.info(session_id) do
      {:ok, %{state: :idle}} = result ->
        result

      {:ok, %{state: state, error: error}} when state in [:failed, :closed, :cancelled] ->
        {:error, error || state}

      {:error, reason} ->
        {:error, reason}

      _pending ->
        if System.monotonic_time(:millisecond) - started >= timeout do
          {:error, {:session_open_timeout, timeout}}
        else
          Process.sleep(25)
          do_await_session_ready(session_id, timeout, started)
        end
    end
  end

  defp strict?, do: System.get_env("JIDO_HARNESS_INTEGRATION_STRICT") in ["1", "true", "yes"]

  defp auth_failure?(reason) do
    reason
    |> inspect(limit: 50, printable_limit: 2_000)
    |> String.match?(~r/auth|credential|api.?key|log.?in|login|unauthorized|forbidden/i)
  end

  defp run_info(nil), do: nil

  defp run_info(run_id) do
    case Jido.Harness.Run.info(run_id) do
      {:ok, info} -> info
      _error -> nil
    end
  end

  defp redacted_status(provider) do
    case Jido.Harness.status(provider) do
      {:ok, status} ->
        %{
          provider: status.provider,
          installed: status.installed,
          compatible: status.compatible,
          authenticated: status.authenticated,
          smoke_ready: status.smoke_ready,
          resume: status.capabilities.resume?,
          native_cancel: status.capabilities.native_cancel?,
          version: redact(status.version),
          executable: status.executable
        }

      {:error, _reason} ->
        %{provider: provider, status: :error}
    end
  end

  defp replay_events(nil), do: []

  defp replay_events(run_id) do
    case Jido.Harness.Run.replay(run_id, cursor: 0, limit: 10_000) do
      {:ok, events} -> events
      _error -> []
    end
  end

  defp write_json(path, value) do
    File.write!(path, Jason.encode!(redact(value), pretty: true))
    File.chmod!(path, 0o600)
  end

  defp write_events(path, events) do
    contents =
      Enum.map_join(events, "", fn event ->
        event
        |> Map.from_struct()
        |> Map.put(:raw, nil)
        |> redact()
        |> Jason.encode!()
        |> Kernel.<>("\n")
      end)

    File.write!(path, contents)
    File.chmod!(path, 0o600)
  end

  defp failure_type(%{__struct__: module}), do: inspect(module)
  defp failure_type({kind, _reason}) when is_atom(kind), do: Atom.to_string(kind)
  defp failure_type(_reason), do: "integration_failure"

  defp redact(%_{} = struct), do: struct |> Map.from_struct() |> redact()

  defp redact(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key), do: {key, "[REDACTED]"}, else: {key, redact(value)}
    end)
  end

  defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)

  defp redact(value) when is_binary(value) do
    redacted =
      value
      |> String.replace(~r/\b(?:sk|xai)-[A-Za-z0-9_-]{8,}\b/, "[REDACTED]")
      |> String.replace(~r/\bBearer\s+[A-Za-z0-9._~-]+\b/i, "Bearer [REDACTED]")

    Enum.reduce(credential_values(), redacted, &String.replace(&2, &1, "[REDACTED]"))
  end

  defp redact(value), do: value

  defp sensitive_key?(key) do
    key = key |> to_string() |> String.downcase()

    key in ["authorization", "password", "api_key", "token", "access_token", "refresh_token"] or
      String.ends_with?(key, ["_key", "_token", "_secret", "_password"])
  end

  defp credential_values do
    @credential_env_names
    |> Enum.map(&System.get_env/1)
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= 6))
    |> Enum.uniq()
  end
end
