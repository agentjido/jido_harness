defmodule Jido.Harness.AdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.Adapters.{Amp, Claude, CLIMapper, Codex, Gemini, Grok, JSONMapper, Kimi, OpenCode, Pi, Zai}
  alias Jido.Harness.{Error, Event, RequestResolver, RunRequest}

  test "Amp builds execute-mode streaming argv with resume and MCP options" do
    request =
      RunRequest.new!(%{
        prompt: "amp",
        provider_session_id: "thread-1",
        mcp_config: %{"server" => %{}},
        reasoning_effort: :high
      })

    assert {:ok, argv} = Amp.build_argv(request, %{labels: ["test"]})
    assert Enum.take(argv, 6) == ["threads", "continue", "thread-1", "--execute", "amp", "--stream-json-thinking"]
    assert Jason.decode!(hd(pairs(argv, "--mcp-config"))) == %{"server" => %{}}
    assert pairs(argv, "--label") == ["test"]
  end

  test "Claude builds print-mode streaming argv with sandbox and resume" do
    request =
      RunRequest.new!(%{
        prompt: "claude",
        provider_session_id: "session-1",
        reasoning_effort: :medium,
        approval_mode: :auto_edit,
        sandbox_mode: :workspace_write
      })

    assert {:ok, argv} = Claude.build_argv(request, %{})

    assert Enum.take(argv, 6) == [
             "--print",
             "--output-format",
             "stream-json",
             "--include-partial-messages",
             "--verbose",
             "--resume"
           ]

    assert pairs(argv, "--resume") == ["session-1"]
    assert pairs(argv, "--effort") == ["medium"]
    assert pairs(argv, "--permission-mode") == ["acceptEdits"]
    assert %{"sandbox" => %{"enabled" => true}} = argv |> pairs("--settings") |> hd() |> Jason.decode!()
    assert Enum.take(argv, -2) == ["--", "claude"]
  end

  test "Z.AI uses the official Claude Code endpoint without exposing its source API-key variable" do
    request =
      RunRequest.new!(%{
        prompt: "zai",
        model: "glm-5.2",
        env: %{"ZAI_API_KEY" => "integration-test-key", "KEEP_ME" => "yes"}
      })

    config = %{env: %{"CONFIGURED" => "yes", "ZAI_API_KEY" => "configured-key"}}
    assert {:ok, env} = Zai.resolve_env(request, config, %{})
    assert env["ANTHROPIC_BASE_URL"] == "https://api.z.ai/api/anthropic"
    assert env["ANTHROPIC_AUTH_TOKEN"] == "integration-test-key"
    assert env["API_TIMEOUT_MS"] == "2147483647"
    assert env["CONFIGURED"] == "yes"
    assert env["KEEP_ME"] == "yes"
    refute Map.has_key?(env, "ZAI_API_KEY")
    assert env["ANTHROPIC_API_KEY"] == nil
    assert env["CLAUDE_AGENT_OAUTH_TOKEN"] == nil
  end

  test "Z.AI validates its endpoint and transport timeout before execution" do
    request = RunRequest.new!(%{prompt: "zai"})

    assert {:error, %Error{category: :validation, provider: :zai}} =
             Zai.resolve_env(request, %{}, %{base_url: ""})

    assert {:error, %Error{category: :validation, provider: :zai}} =
             Zai.resolve_env(request, %{}, %{api_timeout_ms: 0})
  end

  test "Gemini builds headless streaming argv and maps read-only to plan mode" do
    request = RunRequest.new!(%{prompt: "gemini", approval_mode: :auto_approve, sandbox_mode: :workspace_write})

    assert {:ok, argv} = Gemini.build_argv(request, %{})
    assert Enum.take(argv, 4) == ["--prompt", "gemini", "--output-format", "stream-json"]
    assert pairs(argv, "--approval-mode") == ["yolo"]
    assert "--sandbox" in argv

    read_only = RunRequest.new!(%{prompt: "gemini", sandbox_mode: :read_only})
    assert {:ok, read_only_argv} = Gemini.build_argv(read_only, %{})
    assert pairs(read_only_argv, "--approval-mode") == ["plan"]
  end

  test "Codex builds direct exec JSONL argv with resume and normalized controls" do
    request =
      RunRequest.new!(%{
        prompt: "codex",
        provider_session_id: "thread-2",
        reasoning_effort: :low,
        approval_mode: :prompt,
        sandbox_mode: :read_only,
        env: %{"HARNESS_TEST" => "yes"}
      })

    assert {:ok, argv} = Codex.build_argv(request, %{})
    assert Enum.take(argv, 4) == ["exec", "--json", "--sandbox", "read-only"]
    assert "approval_policy=\"on-request\"" in pairs(argv, "--config")
    assert "model_reasoning_effort=\"low\"" in pairs(argv, "--config")
    assert Enum.take(argv, -3) == ["resume", "thread-2", "codex"]
  end

  test "removed Codex SDK escape hatches are rejected" do
    assert {:error, %Error{category: :validation, details: %{key: :codex_options}}} =
             RequestResolver.resolve(:codex, %{prompt: "codex", provider_options: %{codex_options: %{}}})
  end

  test "Grok builds the documented headless argv without a shell" do
    request =
      RunRequest.new!(%{
        prompt: "grok prompt",
        model: "grok-code",
        provider_session_id: "session-3",
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
        provider_session_id: "open-session",
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
        provider_session_id: "ses_123",
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
               provider_session_id: "ses_123",
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
    request = RunRequest.new!(%{prompt: "kimi", provider_session_id: "ses_123"})

    assert {:error, %Error{category: :validation, provider: :kimi}} =
             Kimi.build_argv(request, %{extra_args: ["--output-format=json"]})

    assert {:error, %Error{category: :validation, details: %{field: :approval_mode}}} =
             RequestResolver.resolve(:kimi, %{prompt: "kimi", approval_mode: :auto_approve})

    assert {:error, %Error{category: :validation, details: %{field: :max_turns}}} =
             RequestResolver.resolve(:kimi, %{prompt: "kimi", max_turns: 2})
  end

  test "Pi builds official JSON-mode argv and disables startup update telemetry" do
    request =
      RunRequest.new!(%{
        prompt: "pi prompt",
        model: "claude-sonnet-4-5",
        provider_session_id: "session-uuid",
        system_prompt: "system",
        allowed_tools: ["read", "grep"],
        disallowed_tools: ["bash"],
        attachments: ["prompt.md", "/tmp/image.png"],
        reasoning_effort: :high,
        env: %{"KEEP_ME" => "yes"}
      })

    assert {:ok, argv} =
             Pi.build_argv(request, %{
               model_provider: "anthropic",
               project_trust: :approve,
               extensions: ["./extension.ts"],
               skills: ["./skills/review"],
               no_context_files: true
             })

    assert Enum.take(argv, 2) == ["--mode", "json"]
    assert pairs(argv, "--provider") == ["anthropic"]
    assert pairs(argv, "--model") == ["claude-sonnet-4-5"]
    assert pairs(argv, "--thinking") == ["high"]
    assert pairs(argv, "--session") == ["session-uuid"]
    assert pairs(argv, "--tools") == ["read,grep"]
    assert pairs(argv, "--exclude-tools") == ["bash"]
    assert pairs(argv, "--system-prompt") == ["system"]
    assert pairs(argv, "--extension") == ["./extension.ts"]
    assert pairs(argv, "--skill") == ["./skills/review"]
    assert "--approve" in argv
    assert "--no-context-files" in argv
    assert Enum.take(argv, -3) == ["@prompt.md", "@/tmp/image.png", "pi prompt"]

    prepared = Pi.prepare_request(request)
    assert prepared.env["PI_SKIP_VERSION_CHECK"] == "1"
    assert prepared.env["PI_TELEMETRY"] == "0"
    assert prepared.env["KEEP_ME"] == "yes"

    assert {:ok, %{recipe: %{argv: ["install", "-g", "--ignore-scripts", "@earendil-works/pi-coding-agent"]}}} =
             Pi.install(%{}, dry_run: true)
  end

  test "Pi maps session, streaming, usage, and tool JSONL records" do
    assert [%Event{provider: :pi, type: :run_started, provider_session_id: "pi-session"}] =
             Pi.map_event(%{"type" => "session", "id" => "pi-session", "cwd" => "/tmp"})

    assert [%Event{type: :output_text_delta, payload: %{"text" => "hello"}}] =
             Pi.map_event(%{
               "type" => "message_update",
               "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "hello"}
             })

    assert [%Event{type: :thinking_delta, payload: %{"text" => "considering"}}] =
             Pi.map_event(%{
               "type" => "message_update",
               "assistantMessageEvent" => %{"type" => "thinking_delta", "delta" => "considering"}
             })

    assert [
             %Event{type: :output_text_final, payload: %{"text" => "final answer"}},
             %Event{type: :usage, payload: %{"input" => 10, "output" => 2, "totalTokens" => 12}}
           ] =
             Pi.map_event(%{
               "type" => "message_end",
               "message" => %{
                 "role" => "assistant",
                 "content" => [%{"type" => "text", "text" => "final answer"}],
                 "usage" => %{"input" => 10, "output" => 2, "totalTokens" => 12}
               }
             })

    assert [
             %Event{
               type: :tool_call,
               payload: %{"call_id" => "tool-1", "name" => "read", "input" => %{"path" => "README.md"}}
             }
           ] =
             Pi.map_event(%{
               "type" => "tool_execution_start",
               "toolCallId" => "tool-1",
               "toolName" => "read",
               "args" => %{"path" => "README.md"}
             })

    assert [
             %Event{
               type: :tool_result,
               payload: %{"call_id" => "tool-1", "name" => "read", "output" => %{"text" => "contents"}}
             }
           ] =
             Pi.map_event(%{
               "type" => "tool_execution_end",
               "toolCallId" => "tool-1",
               "toolName" => "read",
               "result" => %{"text" => "contents"},
               "isError" => false
             })

    assert [%Event{type: :provider_event}] =
             Pi.map_event(%{
               "type" => "agent_end",
               "willRetry" => true,
               "messages" => [
                 %{"role" => "assistant", "stopReason" => "error", "errorMessage" => "temporary"}
               ]
             })

    assert [%Event{type: :run_failed, payload: %{"error" => "authentication failed"}}] =
             Pi.map_event(%{
               "type" => "agent_end",
               "willRetry" => false,
               "messages" => [
                 %{"role" => "assistant", "stopReason" => "error", "errorMessage" => "authentication failed"}
               ]
             })
  end

  test "Pi rejects conflicting sessions, unsafe credential argv, and unsupported controls" do
    session_request = RunRequest.new!(%{prompt: "pi", provider_session_id: "session-uuid"})

    assert {:error, %Error{category: :validation, provider: :pi}} =
             Pi.build_argv(session_request, %{continue: true})

    assert {:error, %Error{category: :validation, details: %{argument: "--api-key=secret"}}} =
             Pi.build_argv(session_request, %{extra_args: ["--api-key=secret"]})

    assert {:error, %Error{category: :validation, details: %{field: :approval_mode}}} =
             RequestResolver.resolve(:pi, %{prompt: "pi", approval_mode: :prompt})

    assert {:ok, %{approval_mode: :auto_approve, sandbox_mode: :unrestricted}} =
             RequestResolver.resolve(:pi, %{
               prompt: "pi",
               approval_mode: :auto_approve,
               sandbox_mode: :unrestricted
             })

    assert {:ok, read_only} = RequestResolver.resolve(:pi, %{prompt: "pi", sandbox_mode: :read_only})
    assert {:ok, read_only_argv} = Pi.build_argv(read_only, %{})
    assert pairs(read_only_argv, "--tools") == ["read,grep,find,ls"]

    assert {:error, %Error{category: :validation, details: %{field: :allowed_tools}}} =
             Pi.build_argv(%{read_only | allowed_tools: ["read", "bash"]}, %{})

    assert {:error, %Error{category: :validation, details: %{field: :sandbox_mode}}} =
             RequestResolver.resolve(:pi, %{prompt: "pi", sandbox_mode: :workspace_write})
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
    assert Enum.map(events, & &1.type) == [:output_text_final, :run_completed]

    assert %Event{
             type: :provider_event,
             payload: %{"type" => "new-event", "mapped" => false},
             raw: %{"type" => "new-event"}
           } =
             JSONMapper.map(:grok, %{"type" => "new-event"})
  end

  test "Codex maps direct exec JSONL records into canonical events" do
    assert [
             %Event{type: :tool_call, payload: %{"name" => "exec_command"}},
             %Event{type: :tool_result, payload: %{"output" => "building", "is_error" => false}}
           ] =
             CLIMapper.codex(%{
               "type" => "item.completed",
               "thread_id" => "thread-1",
               "item" => %{
                 "type" => "command_execution",
                 "id" => "item-1",
                 "command" => "build",
                 "aggregated_output" => "building",
                 "exit_code" => 0
               }
             })

    assert [%Event{type: :file_change, payload: %{"diff" => "@@ -1 +1 @@"}}] =
             CLIMapper.codex(%{
               "type" => "turn.diff.updated",
               "thread_id" => "thread-1",
               "turn_id" => "turn-1",
               "diff" => "@@ -1 +1 @@"
             })

    assert [
             %Event{
               type: :plan_updated,
               payload: %{
                 "explanation" => "checking",
                 "plan" => [%{"step" => "test", "status" => :in_progress}]
               }
             }
           ] =
             CLIMapper.codex(%{
               "type" => "turn.plan.updated",
               "thread_id" => "thread-1",
               "turn_id" => "turn-1",
               "explanation" => "checking",
               "plan" => [%{"step" => "test", "status" => :in_progress}]
             })

    assert [%Event{type: :thinking_delta, payload: %{"text" => "reasoning"}}] =
             CLIMapper.codex(%{
               "type" => "item.completed",
               "thread_id" => "thread-1",
               "item" => %{"type" => "reasoning", "text" => "reasoning"}
             })
  end

  test "all requested providers publish a truthful default session transport" do
    expected = %{
      amp: :stream_json_resume,
      claude: :stream_json_resume,
      codex: :exec_jsonl_resume,
      gemini: :stream_json_resume,
      grok: :streaming_json_resume,
      kimi: :acp,
      opencode: :acp,
      pi: :rpc,
      zai: :stream_json_resume
    }

    Enum.each(expected, fn {provider, transport} ->
      {:ok, spec} = Jido.Harness.Registry.spec(provider)
      assert spec.default_session_transport == transport
      assert Enum.any?(spec.session_transports, &(&1.name == transport))
    end)

    refute Enum.any?(Codex.spec().session_transports, &(&1.name == :app_server))
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
