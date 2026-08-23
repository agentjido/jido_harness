defmodule Jido.Harness.CodexStructuredOutputTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.{Error, Event, Run, RunRequest}
  alias Jido.Harness.Adapters.Codex
  alias Jido.Harness.StructuredOutput.{SchemaWorkspace, Stream, WorkspaceGuard}

  @schema %{
    "type" => "object",
    "properties" => %{
      "department" => %{"type" => "string", "enum" => ["people", "finance"]},
      "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1}
    },
    "required" => ["department", "confidence"],
    "additionalProperties" => false
  }

  defmodule IncompatibleProcessManager do
    alias Jido.Harness.{ProcessEvent, ProcessInfo}

    def start_owned_process(%{argv: ["--version"]}, _owner), do: {:ok, "version"}

    def await_process("version", _timeout),
      do: {:ok, ProcessInfo.new!(process_id: "version", state: :exited, started_at: timestamp())}

    def replay_process("version", _options) do
      {:ok,
       [
         ProcessEvent.new!(
           process_id: "version",
           sequence: 1,
           timestamp: timestamp(),
           type: :stdout,
           data: "codex-cli 0.100.0\n"
         )
       ]}
    end

    def prune_process("version"), do: :ok
    defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defmodule CompatibleStartFailureManager do
    alias Jido.Harness.{ProcessEvent, ProcessInfo}

    def start_owned_process(%{argv: ["--version"]}, _owner), do: {:ok, "version"}
    def start_owned_process(%{argv: ["exec", "--help"]}, _owner), do: {:ok, "help"}
    def start_owned_process(%{argv: argv}, _owner) when is_list(argv), do: {:error, :provider_start_failed}

    def await_process(id, _timeout) when id in ["version", "help"],
      do: {:ok, ProcessInfo.new!(process_id: id, state: :exited, started_at: timestamp())}

    def replay_process(id, _options) do
      output =
        if id == "version",
          do: "codex-cli 0.144.6\n",
          else: "--output-schema --ephemeral --ignore-user-config --ignore-rules\n"

      {:ok, [ProcessEvent.new!(process_id: id, sequence: 1, timestamp: timestamp(), type: :stdout, data: output)]}
    end

    def prune_process(_id), do: :ok
    defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
  end

  setup do
    fixture = Jido.Harness.TestHelpers.fixture_path("fake_stream_cli.exs")
    original_config = Application.get_env(:jido_harness, :provider_config, %{})
    original_api_key = System.get_env("OPENAI_API_KEY")
    original_codex_key = System.get_env("CODEX_API_KEY")

    Application.put_env(
      :jido_harness,
      :provider_config,
      Map.put(original_config, :codex, %{cli_path: fixture, env: %{"OPENAI_API_KEY" => "configured-secret"}})
    )

    System.put_env("OPENAI_API_KEY", "ambient-secret")
    System.put_env("CODEX_API_KEY", "ambient-codex-secret")

    on_exit(fn ->
      Application.put_env(:jido_harness, :provider_config, original_config)
      restore_env("OPENAI_API_KEY", original_api_key)
      restore_env("CODEX_API_KEY", original_codex_key)
      Jido.Harness.TestHelpers.cleanup_runs()
      Jido.Harness.TestHelpers.cleanup_processes()
    end)

    :ok
  end

  test "builds the reviewed ephemeral read-only Codex invocation" do
    request = request()

    assert {:ok, argv} = Codex.build_argv(request, %{}, "/private/schema.json")
    assert Enum.take(argv, 2) == ["exec", "--json"]
    assert "--ephemeral" in argv
    assert "--ignore-user-config" in argv
    assert "--ignore-rules" in argv
    assert pairs(argv, "--output-schema") == ["/private/schema.json"]
    assert pairs(argv, "--sandbox") == ["read-only"]
    assert "approval_policy=\"never\"" in pairs(argv, "--config")
    assert "project_doc_max_bytes=0" in pairs(argv, "--config")
    assert "shell_environment_policy.inherit=\"none\"" in pairs(argv, "--config")
    assert List.last(argv) == "classify"
  end

  test "returns one schema-validated result through the managed finite-run API" do
    before = workspace_directories()

    assert {:ok, result} = Jido.Harness.run(:codex, Map.from_struct(request()), await_timeout: 10_000)
    assert result.status == :completed
    assert Jason.decode!(result.text) == %{"department" => "people", "confidence" => 0.9}

    assert result.structured_output == %{
             "schema_id" => "hr.classification.v1",
             "value" => %{"department" => "people", "confidence" => 0.9}
           }

    assert result.provider_session_id == nil
    assert Enum.count(result.events, &Event.run_terminal?/1) == 1
    assert Enum.any?(result.events, &(&1.type == :structured_output))
    assert workspace_directories() == before
  end

  test "rejects sessions, ambient inputs, writable modes, and provider behavior switches before execution" do
    base = Map.from_struct(request())

    for attrs <- [
          Map.put(base, :provider_session_id, "retained"),
          Map.put(base, :add_dirs, ["/tmp"]),
          Map.put(base, :attachments, ["private.png"]),
          Map.put(base, :env, %{"OPENAI_API_KEY" => "direct-secret"}),
          Map.put(base, :sandbox_mode, :workspace_write),
          Map.put(base, :approval_mode, :prompt),
          Map.put(base, :provider_options, %{resume_last: true})
        ] do
      assert {:ok, run_id} = Run.start(:codex, attrs)
      assert {:ok, result} = Run.await(run_id, 5_000)
      assert result.status == :failed
      assert %Error{category: :validation, details: %{failure_kind: :incompatible_option}} = result.error
    end
  end

  test "normalizes missing, duplicate, malformed, oversized, and schema-invalid output" do
    output = request().structured_output

    failures = [
      {[], "missing_terminal_output"},
      {[final(~s({"department":"people","confidence":0.9})), final(~s({"department":"people","confidence":0.9}))],
       "duplicate_terminal_output"},
      {[final("not-json")], "malformed_terminal_json"},
      {[final(~s({"department":"legal","confidence":0.9}))], "schema_validation_failed"},
      {[final(String.duplicate("x", output.max_output_bytes + 1))], "terminal_output_too_large"}
    ]

    Enum.each(failures, fn {prefix, expected_kind} ->
      events = enumerate(prefix ++ [completed()], output)
      assert [%Event{type: :run_failed, payload: %{"failure_kind" => ^expected_kind}}] = events
    end)
  end

  test "workspace guard cleans when its owner terminates" do
    output = request().structured_output
    parent = self()

    owner =
      spawn(fn ->
        {:ok, workspace} = SchemaWorkspace.open(output)
        {:ok, _guard} = WorkspaceGuard.start(workspace, self())
        send(parent, {:guarded_workspace, workspace.directory})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:guarded_workspace, directory}
    assert File.dir?(directory)
    Process.exit(owner, :kill)
    assert eventually(fn -> not File.exists?(directory) end)
  end

  test "managed cancellation removes the private workspace" do
    before = workspace_directories()
    waiting = %{Map.from_struct(request()) | prompt: "structured-wait"}

    assert {:ok, run_id} = Run.start(:codex, waiting)
    assert eventually(fn -> MapSet.size(MapSet.difference(workspace_directories(), before)) == 1 end)
    assert :ok = Run.cancel(run_id)
    assert {:ok, result} = Run.await(run_id, 5_000)
    assert result.status == :cancelled
    assert eventually(fn -> workspace_directories() == before end)
  end

  test "rejects an incompatible CLI before staging or starting a model run" do
    before = workspace_directories()

    request =
      request()
      |> Map.from_struct()
      |> Map.put(:provider_options, %{cli_path: "incompatible-codex"})
      |> RunRequest.new!()

    context = %{
      run_id: "compatibility-test",
      run_owner: self(),
      process_manager: IncompatibleProcessManager,
      config: %{}
    }

    assert {:error,
            %Error{
              category: :configuration,
              details: %{failure_kind: :incompatible_cli, minimum_version: "0.144.6"}
            }} = Codex.run(request, context)

    assert workspace_directories() == before
  end

  test "normalizes provider start failure and removes its staged workspace" do
    before = workspace_directories()

    request =
      request()
      |> Map.from_struct()
      |> Map.put(:provider_options, %{cli_path: "compatible-but-unstartable"})
      |> RunRequest.new!()

    context = %{
      run_id: "start-failure-test",
      run_owner: self(),
      process_manager: CompatibleStartFailureManager,
      config: %{}
    }

    assert {:error, %Error{details: %{failure_kind: :provider_start_failed}}} = Codex.run(request, context)
    assert workspace_directories() == before
  end

  test "provider crash and timeout are terminal failures with no retained workspace" do
    before = workspace_directories()

    crash = %{Map.from_struct(request()) | prompt: "structured-crash"}
    assert {:ok, crash_result} = Jido.Harness.run(:codex, crash, await_timeout: 10_000)
    assert crash_result.status == :failed
    assert crash_result.error.details.failure_kind == "provider_execution_failed"
    assert eventually(fn -> workspace_directories() == before end)

    timeout = %{Map.from_struct(request()) | prompt: "structured-wait", runtime_timeout_ms: 1_000}
    assert {:ok, timeout_result} = Jido.Harness.run(:codex, timeout, await_timeout: 10_000)
    assert timeout_result.status == :failed
    assert timeout_result.error.category == :timeout
    assert eventually(fn -> workspace_directories() == before end)
  end

  test "readiness verifies cached subscription authentication without API-key fallback" do
    fixture = Jido.Harness.TestHelpers.fixture_path("fake_stream_cli.exs")

    assert {:ok, status} = Codex.status(%{cli_path: fixture})
    assert status.installed
    assert status.compatible
    refute status.authenticated
    refute status.smoke_ready
    assert status.error == :cached_subscription_authentication_missing
  end

  test "cleanup failures are generic and path-free" do
    workspace = %SchemaWorkspace{directory: <<0>>, schema_path: "private", working_directory: "private"}
    assert {:error, %Error{details: %{failure_kind: :schema_staging_failed}} = error} = SchemaWorkspace.close(workspace)
    refute inspect(error) =~ "private"
  end

  defp request do
    RunRequest.new!(%{
      prompt: "classify",
      sandbox_mode: :read_only,
      approval_mode: :auto_approve,
      structured_output: %{schema_id: "hr.classification.v1", schema: @schema}
    })
  end

  defp enumerate(events, output) do
    {:ok, workspace} = SchemaWorkspace.open(output)
    {:ok, guard} = WorkspaceGuard.start(workspace, self())
    events |> Stream.wrap(output, guard) |> Enum.to_list()
  end

  defp final(text), do: Event.new!(provider: :codex, type: :output_text_final, payload: %{"text" => text})
  defp completed, do: Event.new!(provider: :codex, type: :run_completed)

  defp workspace_directories do
    System.tmp_dir!()
    |> Path.join("jido-harness-structured-output/run-*")
    |> Path.wildcard()
    |> MapSet.new()
  end

  defp pairs(argv, flag) do
    argv
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {^flag, index} -> [Enum.at(argv, index + 1)]
      _entry -> []
    end)
  end

  defp eventually(function, attempts \\ 100)
  defp eventually(function, 0), do: function.()

  defp eventually(function, attempts) do
    if function.() do
      true
    else
      Process.sleep(10)
      eventually(function, attempts - 1)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
