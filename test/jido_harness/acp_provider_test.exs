defmodule Jido.Harness.ACPProviderTest do
  use ExUnit.Case, async: false

  setup do
    acp_fixture = Jido.Harness.TestHelpers.fixture_path("fake_acp_cli.py")
    original = Application.get_env(:jido_harness, :provider_config, %{})

    provider_config =
      [:amp, :claude, :codex, :cursor, :gemini, :grok, :zai, :opencode]
      |> Map.new(&{&1, %{acp_path: acp_fixture}})

    Application.put_env(:jido_harness, :provider_config, Map.merge(original, provider_config))

    on_exit(fn ->
      Jido.Harness.TestHelpers.cleanup_runs()
      Jido.Harness.TestHelpers.cleanup_sessions()
      Application.put_env(:jido_harness, :provider_config, original)
    end)

    :ok
  end

  test "OpenCode resumes finite runs through ACP session loading" do
    assert {:ok, first} = Jido.Harness.run(:opencode, "first", await_timeout: 5_000)

    assert {:ok, second} =
             Jido.Harness.run(:opencode, "second", provider_session_id: first.provider_session_id, await_timeout: 5_000)

    assert second.status == :completed
    assert second.provider_session_id == first.provider_session_id

    assert {:ok, loaded} =
             Jido.Harness.run(:opencode, "loaded", provider_session_id: "saved-opencode-session", await_timeout: 5_000)

    assert loaded.provider_session_id == "saved-opencode-session"
  end

  test "Codex isolation controls preserve writable finite runs" do
    cwd = Path.join(System.tmp_dir!(), "harness-isolation-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)

    assert {:ok, result} =
             Jido.Harness.run(:codex, "write-isolated-fixture",
               cwd: cwd,
               sandbox_mode: :workspace_write,
               approval_mode: :auto_approve,
               provider_options: %{ephemeral: true, ignore_user_config: true},
               env: %{"HARNESS_FIXTURE_ISOLATION_SUPPORT" => "1", "HARNESS_FIXTURE_CODEX_CONFIGURATION" => "1"},
               await_timeout: 5_000
             )

    assert result.status == :completed
    assert File.read!(Path.join(cwd, "isolated-result.txt")) == "workspace remains writable"
  end

  test "Codex isolation defaults, string keys, and unsupported adapters are explicit" do
    alias Jido.Harness.Adapters.Codex
    assert {:ok, request} = Jido.Harness.SessionRequest.new(%{})
    assert {:ok, %{}} = Codex.acp_env(request, %{})
    assert {:ok, result} = Jido.Harness.run(:codex, "fixture", await_timeout: 5_000)
    assert result.status == :completed

    assert {:ok, result} =
             Jido.Harness.run(:codex, "fixture",
               provider_options: %{"ephemeral" => true, "ignore_user_config" => true},
               env: %{"HARNESS_FIXTURE_ISOLATION_SUPPORT" => "1"},
               await_timeout: 5_000
             )

    assert result.status == :completed

    assert {:ok, failed} =
             Jido.Harness.run(:codex, "fixture", provider_options: %{ephemeral: true}, await_timeout: 5_000)

    assert failed.status == :failed
    assert %Jido.Harness.Error{category: :configuration, details: %{option: :ephemeral}} = failed.error
    refute Enum.any?(failed.events, &(&1.type == :output_text_delta))
  end

  test "Codex validates isolation values and rejects ephemeral resume before startup" do
    assert {:error, %Jido.Harness.Error{category: :validation}} =
             Jido.Harness.Run.start(:codex, %{prompt: "fixture", provider_options: %{ephemeral: "true"}})

    assert {:error, %Jido.Harness.Error{category: :validation}} =
             Jido.Harness.Session.start(:codex, %{provider_options: %{ephemeral: "true"}})

    assert {:error, %Jido.Harness.Error{message: "ephemeral Codex execution cannot resume a session"}} =
             Jido.Harness.Run.start(:codex, %{
               prompt: "fixture",
               provider_session_id: "saved",
               provider_options: %{ephemeral: true}
             })

    assert {:error, %Jido.Harness.Error{message: "ephemeral Codex execution cannot resume a session"}} =
             Jido.Harness.Session.start(:codex, %{provider_session_id: "saved", provider_options: %{ephemeral: true}})
  end

  test "OpenCode sets initial and runtime models without session/set_model" do
    log = Path.join(System.tmp_dir!(), "harness-model-#{System.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm(log) end)

    env = %{
      "HARNESS_FIXTURE_CONFIGURATION_PROTOCOL" => "config",
      "HARNESS_FIXTURE_CONFIGURATION_LOG" => log
    }

    assert {:ok, result} = Jido.Harness.run(:opencode, "fixture", model: "initial", env: env, await_timeout: 5_000)
    assert result.status == :completed
    assert {:ok, session} = Jido.Harness.Session.start(:opencode, %{model: "initial", env: env})
    assert {:ok, _info} = await_ready(session)
    assert :ok = Jido.Harness.Session.configure(session, %{model: "changed"})
    assert {:ok, turn} = Jido.Harness.Session.send_message(session, "fixture")
    assert {:ok, %{status: :completed}} = Jido.Harness.Session.await(session, turn, 5_000)

    calls = log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.map(calls, & &1["method"]) == List.duplicate("session/set_config_option", 3)
    assert Enum.map(calls, & &1["params"]["configId"]) == List.duplicate("model", 3)
    assert Enum.map(calls, & &1["params"]["value"]) == ["initial", "initial", "changed"]
  end

  test "model configuration falls back only when config options are not implemented" do
    assert {:ok, result} =
             Jido.Harness.run(:codex, "fixture",
               model: "legacy-model",
               env: %{"HARNESS_FIXTURE_CONFIGURATION_PROTOCOL" => "legacy"},
               await_timeout: 5_000
             )

    assert result.status == :completed

    assert {:ok, session} =
             Jido.Harness.Session.start(:opencode, %{env: %{"HARNESS_FIXTURE_CONFIGURATION_PROTOCOL" => "invalid"}})

    assert {:ok, _info} = await_ready(session)

    assert {:error, %{"code" => -32602, "message" => "Invalid model"}} =
             Jido.Harness.Session.configure(session, %{model: "invalid"})
  end

  test "results retain original ACP messages while journal replay and streams omit raw data" do
    assert {:ok, result} = Jido.Harness.run(:grok, "fixture", await_timeout: 5_000)
    event = Enum.find(result.events, &(&1.type == :output_text_delta))
    assert event.payload == %{"text" => "fixture-ok"}
    assert event.raw["jsonrpc"] == "2.0"
    assert event.raw["method"] == "session/update"
    assert event.raw["providerEnvelope"]["trace"] == "fixture-envelope"
    assert event.raw["params"]["sessionId"] == result.provider_session_id
    assert event.raw["params"]["providerParameter"] == "fixture-parameter"
    assert event.raw["params"]["update"]["sessionUpdate"] == "agent_message_chunk"
    assert event.raw["params"]["update"]["providerExtension"] == %{"trace" => "fixture-trace"}
    assert {:ok, replay} = Jido.Harness.Run.replay(result.run_id, limit: 100)
    replayed = Enum.find(replay, &(&1.sequence == event.sequence))
    assert replayed.payload == event.payload
    assert replayed.raw == nil
    assert {:ok, stream} = Jido.Harness.Run.stream(result.run_id, poll_interval_ms: 1)
    streamed = Enum.find(stream, &(&1.sequence == event.sequence))
    assert streamed.payload == event.payload
    assert streamed.raw == nil
  end

  test "all finite provider runs use the same ACP interface" do
    Enum.each([:amp, :claude, :codex, :cursor, :gemini, :grok, :zai], fn provider ->
      assert {:ok, run_id} = Jido.Harness.Run.start(provider, %{prompt: "fixture"})
      assert {:ok, result} = Jido.Harness.Run.await(run_id, 5_000)
      assert result.status == :completed
      assert result.text == "fixture-ok"
      assert result.provider_session_id == "acp-fixture-session"
      assert result.usage == %{"size" => 10, "used" => 3}
      assert Enum.any?(result.events, &match?(%{type: :provider_event, payload: %{"kind" => "acp_session_ready"}}, &1))
    end)
  end

  test "Cursor authenticates before it opens an ACP session" do
    assert {:ok, result} =
             Jido.Harness.run(:cursor, "fixture",
               env: %{"HARNESS_FIXTURE_REQUIRE_AUTH_METHOD" => "cursor_login"},
               await_timeout: 5_000
             )

    assert result.status == :completed
    assert result.text == "fixture-ok"
  end

  test "stateful sessions use the same ACP interface as finite runs" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:gemini)
    assert {:ok, first_turn} = Jido.Harness.Session.send_message(session_id, "first")
    assert {:ok, first} = Jido.Harness.Session.await(session_id, first_turn, 5_000)
    assert first.status == :completed
    assert first.provider_session_id == "acp-fixture-session"

    assert {:ok, second_turn} = Jido.Harness.Session.send_message(session_id, "second")
    assert {:ok, second} = Jido.Harness.Session.await(session_id, second_turn, 5_000)
    assert second.status == :completed
    assert second.provider_session_id == "acp-fixture-session"
  end

  test "a native ACP provider has one terminal run event" do
    assert {:ok, run_id} = Jido.Harness.Run.start(:grok, %{prompt: "fixture"})
    assert {:ok, result} = Jido.Harness.Run.await(run_id, 5_000)

    assert result.status == :completed
    assert result.text == "fixture-ok"
    assert result.error == nil

    assert {:ok, events} = Jido.Harness.Run.replay(run_id, limit: 100)

    refute Enum.any?(events, &(&1.type == :run_failed))
    assert Enum.count(events, &Jido.Harness.Event.run_terminal?/1) == 1
    assert List.last(events).type == :run_completed
  end

  defp await_ready(session, attempts \\ 100)
  defp await_ready(_session, 0), do: {:error, :timeout}

  defp await_ready(session, attempts) do
    case Jido.Harness.Session.info(session) do
      {:ok, %{state: :idle}} = result ->
        result

      _ ->
        Process.sleep(20)
        await_ready(session, attempts - 1)
    end
  end
end
