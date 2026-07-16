defmodule Jido.Harness.AdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.Adapters.{Amp, Claude, Codex, Gemini, Grok, JSONMapper, Kimi, OpenCode, Zai}
  alias Jido.Harness.{Error, Event, RequestResolver, RunRequest}

  setup do
    Process.put(:capture_owner, self())
    :ok
  end

  test "Amp SDK receives normalized long-run and resume options" do
    request =
      RunRequest.new!(%{
        prompt: "amp",
        session_id: "thread-1",
        mcp_config: %{"server" => %{}},
        reasoning_effort: :high
      })

    assert {:ok, stream} = Amp.run(request, %{config: %{sdk_module: Jido.Harness.AmpCaptureSDK}})
    assert Enum.to_list(stream) == []
    assert_receive {:amp_options, "amp", options}
    assert options.continue_thread == "thread-1"
    assert options.mcp_config == %{"server" => %{}}
    assert options.thinking
    assert options.stream_timeout_ms == 2_147_483_647
  end

  test "Claude SDK receives normalized reasoning, sandbox, and resume options" do
    request =
      RunRequest.new!(%{
        prompt: "claude",
        session_id: "session-1",
        reasoning_effort: :medium,
        approval_mode: :auto_edit,
        sandbox_mode: :workspace_write
      })

    assert {:ok, stream} =
             Claude.run(request, %{config: %{sdk_module: Jido.Harness.ClaudeCaptureSDK}})

    assert Enum.to_list(stream) == []
    assert_receive {:claude_options, {:resume, "session-1"}, "claude", options}
    assert options.max_thinking_tokens == 4_096
    assert options.permission_mode == :accept_edits
    assert options.sandbox == %{enabled: true}
    assert options.timeout_ms == 2_147_483_647
  end

  test "Z.AI uses the official Claude Code endpoint without exposing its source API-key variable" do
    request =
      RunRequest.new!(%{
        prompt: "zai",
        model: "glm-5.2",
        env: %{"ZAI_API_KEY" => "integration-test-key", "KEEP_ME" => "yes"}
      })

    context = %{
      config: %{
        sdk_module: Jido.Harness.ZaiCaptureSDK,
        env: %{"CONFIGURED" => "yes", "ZAI_API_KEY" => "configured-key"}
      }
    }

    assert {:ok, stream} = Zai.run(request, context)
    assert [%Event{provider: :zai, type: :session_started, session_id: "zai-session"}] = Enum.to_list(stream)
    assert_receive {:zai_options, :query, "zai", options}
    assert options.model == "glm-5.2"
    assert options.env["ANTHROPIC_BASE_URL"] == "https://api.z.ai/api/anthropic"
    assert options.env["ANTHROPIC_AUTH_TOKEN"] == "integration-test-key"
    assert options.env["API_TIMEOUT_MS"] == "2147483647"
    assert options.env["CONFIGURED"] == "yes"
    assert options.env["KEEP_ME"] == "yes"
    refute Map.has_key?(options.env, "ZAI_API_KEY")

    child_env = ClaudeAgentSDK.Process.__env_vars__(options)
    refute Map.has_key?(child_env, "ANTHROPIC_API_KEY")
    refute Map.has_key?(child_env, "CLAUDE_AGENT_OAUTH_TOKEN")
  end

  test "Z.AI validates its endpoint and transport timeout before execution" do
    request = RunRequest.new!(%{prompt: "zai"})

    assert {:error, %Error{category: :validation, provider: :zai}} =
             Zai.resolve_env(request, %{}, %{base_url: ""})

    assert {:error, %Error{category: :validation, provider: :zai}} =
             Zai.resolve_env(request, %{}, %{api_timeout_ms: 0})
  end

  test "Gemini SDK receives supported normalized options and rejects read-only" do
    request = RunRequest.new!(%{prompt: "gemini", approval_mode: :auto_approve, sandbox_mode: :workspace_write})

    assert {:ok, stream} =
             Gemini.run(request, %{config: %{sdk_module: Jido.Harness.GeminiCaptureSDK}})

    assert Enum.to_list(stream) == []
    assert_receive {:gemini_options, "gemini", options}
    assert options.approval_mode == :yolo
    assert options.sandbox
    assert options.timeout_ms == 2_147_483_647

    read_only = RunRequest.new!(%{prompt: "gemini", sandbox_mode: :read_only})
    assert {:error, %Error{category: :validation}} = Gemini.run(read_only, %{config: %{}})
  end

  test "Codex SDK receives structured thread and turn options" do
    request =
      RunRequest.new!(%{
        prompt: "codex",
        session_id: "thread-2",
        reasoning_effort: :low,
        approval_mode: :prompt,
        sandbox_mode: :read_only,
        env: %{"HARNESS_TEST" => "yes"}
      })

    context = %{
      config: %{
        sdk_module: Jido.Harness.CodexCaptureSDK,
        thread_module: Jido.Harness.CodexCaptureThread,
        streaming_module: Jido.Harness.CodexCaptureStreaming
      }
    }

    assert {:ok, stream} = Codex.run(request, context)
    assert Enum.to_list(stream) == []
    assert_receive {:codex_options, {:resume, "thread-2"}, options, thread_options}
    assert options.reasoning_effort == :low
    assert thread_options.ask_for_approval == :on_request
    assert thread_options.sandbox == :read_only
    assert thread_options.shell_environment_policy == %{"set" => %{"HARNESS_TEST" => "yes"}}
    assert_receive {:codex_turn, "codex", turn_options}
    assert turn_options.timeout_ms == 2_147_483_647
    assert turn_options.completion_timeout_ms == 2_147_483_647
    assert turn_options.env == %{"HARNESS_TEST" => "yes"}
  end

  test "Codex nested escape hatches cannot override explicit normalized values" do
    request =
      RunRequest.new!(%{
        prompt: "codex",
        model: "normalized-model",
        max_turns: 2,
        reasoning_effort: :high,
        sandbox_mode: :workspace_write,
        provider_options: %{
          codex_options: %{reasoning_effort: :low},
          thread_options: %{model: "shadow-model", sandbox: :danger_full_access},
          turn_options: %{max_turns: 99}
        }
      })

    context = %{
      config: %{
        sdk_module: Jido.Harness.CodexCaptureSDK,
        thread_module: Jido.Harness.CodexCaptureThread,
        streaming_module: Jido.Harness.CodexCaptureStreaming
      }
    }

    assert {:ok, stream} = Codex.run(request, context)
    assert Enum.to_list(stream) == []
    assert_receive {:codex_options, :start, options, thread_options}
    assert options.reasoning_effort == :high
    assert thread_options.model == "normalized-model"
    assert thread_options.sandbox == :workspace_write
    assert_receive {:codex_turn, "codex", turn_options}
    assert turn_options.max_turns == 2
  end

  test "Grok builds the documented headless argv without a shell" do
    request =
      RunRequest.new!(%{
        prompt: "grok prompt",
        model: "grok-code",
        session_id: "session-3",
        max_turns: 2,
        system_prompt: "system",
        allowed_tools: ["Read", "Grep"],
        disallowed_tools: ["Bash"],
        approval_mode: :auto_edit,
        sandbox_mode: :read_only,
        reasoning_effort: :high
      })

    assert {:ok, argv} =
             Grok.build_argv(request, %{allow_rules: ["Bash(git *)"], deny_rules: ["Bash(rm *)"]})

    assert Enum.take(argv, 6) == [
             "--no-auto-update",
             "--no-alt-screen",
             "-p",
             "grok prompt",
             "--output-format",
             "streaming-json"
           ]

    assert pairs(argv, "--resume") == ["session-3"]
    assert pairs(argv, "--system-prompt-override") == ["system"]
    assert pairs(argv, "--tools") == ["Read,Grep"]
    assert pairs(argv, "--permission-mode") == ["acceptEdits"]
    assert pairs(argv, "--sandbox") == ["read-only"]
    assert pairs(argv, "--allow") == ["Bash(git *)"]
    assert pairs(argv, "--deny") == ["Bash(rm *)"]
    refute "--session" in argv
  end

  test "OpenCode maps session, attachments, reasoning, and approval to argv" do
    request =
      RunRequest.new!(%{
        prompt: "open prompt",
        model: "provider/model",
        session_id: "open-session",
        attachments: ["one.png", "two.png"],
        reasoning_effort: :medium,
        approval_mode: :auto_approve
      })

    assert {:ok, argv} = OpenCode.build_argv(request, %{agent: "build", thinking: true})
    assert List.first(argv) == "run"
    assert List.last(argv) == "open prompt"
    assert pairs(argv, "--session") == ["open-session"]
    assert pairs(argv, "--file") == ["one.png", "two.png"]
    assert pairs(argv, "--variant") == ["medium"]
    assert "--auto" in argv
    assert "--thinking" in argv
    assert pairs(argv, "--format") == ["json"]
  end

  test "Kimi builds official print-mode argv and managed long-run environment" do
    request =
      RunRequest.new!(%{
        prompt: "kimi prompt",
        model: "k3",
        session_id: "ses_123",
        add_dirs: ["../shared", "/tmp/extra"],
        reasoning_effort: :high,
        env: %{"KIMI_MODEL_API_KEY" => "integration-test-key"}
      })

    assert {:ok, prepared} = Kimi.prepare_request(request)
    assert prepared.env["KIMI_MODEL_NAME"] == "k3"
    assert prepared.env["KIMI_MODEL_API_KEY"] == "integration-test-key"
    assert prepared.env["KIMI_MODEL_THINKING_EFFORT"] == "high"
    assert prepared.env["KIMI_CODE_NO_AUTO_UPDATE"] == "1"
    assert prepared.env["KIMI_DISABLE_CRON"] == "1"
    assert prepared.env["KIMI_CODE_BACKGROUND_KEEP_ALIVE_ON_EXIT"] == "0"

    assert {:ok, argv} = Kimi.build_argv(prepared, %{skills_dirs: ["./team-skills"]})
    assert Enum.take(argv, 4) == ["-p", "kimi prompt", "--output-format", "stream-json"]
    assert pairs(argv, "--session") == ["ses_123"]
    assert pairs(argv, "--add-dir") == ["../shared", "/tmp/extra"]
    assert pairs(argv, "--skills-dir") == ["./team-skills"]
    refute "--model" in argv

    cached_request = RunRequest.new!(%{prompt: "cached", model: "configured-alias"})
    assert {:ok, cached_argv} = Kimi.build_argv(cached_request, %{})
    assert pairs(cached_argv, "--model") == ["configured-alias"]
  end

  test "Kimi maps its official assistant, tool, and resume JSONL records" do
    assistant = %{
      "role" => "assistant",
      "content" => "checking",
      "tool_calls" => [
        %{
          "type" => "function",
          "id" => "tc_1",
          "function" => %{"name" => "Shell", "arguments" => ~s({"command":"ls"})}
        }
      ]
    }

    assert [
             %Event{provider: :kimi, type: :output_text_delta, payload: %{"text" => "checking"}},
             %Event{
               provider: :kimi,
               type: :tool_call,
               payload: %{"call_id" => "tc_1", "name" => "Shell", "input" => %{"command" => "ls"}}
             }
           ] = Kimi.map_event(assistant)

    assert [
             %Event{
               provider: :kimi,
               type: :tool_result,
               payload: %{"call_id" => "tc_1", "output" => "file.py", "is_error" => false}
             }
           ] = Kimi.map_event(%{"role" => "tool", "tool_call_id" => "tc_1", "content" => "file.py"})

    assert [
             %Event{
               provider: :kimi,
               type: :provider_event,
               session_id: "ses_123",
               payload: %{"type" => "session.resume_hint"}
             }
           ] =
             Kimi.map_event(%{
               "role" => "meta",
               "type" => "session.resume_hint",
               "session_id" => "ses_123",
               "command" => "kimi -r ses_123",
               "content" => "resume"
             })
  end

  test "Kimi rejects conflicting or unsupported normalized controls" do
    request = RunRequest.new!(%{prompt: "kimi", session_id: "ses_123"})

    assert {:error, %Error{category: :validation, provider: :kimi}} =
             Kimi.build_argv(request, %{extra_args: ["--output-format=json"]})

    assert {:error, %Error{category: :validation, details: %{field: :approval_mode}}} =
             RequestResolver.resolve(:kimi, %{prompt: "kimi", approval_mode: :auto_approve})

    assert {:error, %Error{category: :validation, details: %{field: :max_turns}}} =
             RequestResolver.resolve(:kimi, %{prompt: "kimi", max_turns: 2})
  end

  test "CLI escape hatches cannot shadow normalized or harness-owned flags" do
    grok_request = RunRequest.new!(%{prompt: "grok", model: "normalized"})
    open_request = RunRequest.new!(%{prompt: "open", approval_mode: :auto_approve})

    assert {:error, %Error{category: :validation, details: %{argument: "--model"}}} =
             Grok.build_argv(grok_request, %{extra_args: ["--model", "shadow"]})

    assert {:error, %Error{category: :validation, details: %{argument: "--format=json"}}} =
             OpenCode.build_argv(open_request, %{extra_args: ["--format=json"]})
  end

  test "generic JSON mapping preserves unknown events and emits canonical terminals" do
    assert %Event{type: :output_text_delta, payload: %{"text" => "hello"}} =
             JSONMapper.map(:grok, %{"type" => "delta", "text" => "hello"})

    events = List.wrap(JSONMapper.map(:opencode, %{"type" => "completed", "text" => "done"}))
    assert Enum.map(events, & &1.type) == [:output_text_final, :session_completed]

    assert %Event{
             type: :provider_event,
             payload: %{"type" => "new-event", "mapped" => false},
             raw: %{"type" => "new-event"}
           } =
             JSONMapper.map(:grok, %{"type" => "new-event"})
  end

  defp pairs(argv, flag) do
    argv
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {^flag, index} -> [Enum.at(argv, index + 1)]
      _ -> []
    end)
  end
end
