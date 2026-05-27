defmodule Jido.Harness.SchemaTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.{Error, Event, Provider, RunRequest, RuntimeContract}

  test "run_request schema constructors validate inputs" do
    assert is_struct(RunRequest.schema())
    assert {:ok, %RunRequest{prompt: "hello", session_id: nil}} = RunRequest.new(%{prompt: "hello"})

    assert %RunRequest{prompt: "hello", session_id: "session-1"} =
             RunRequest.new!(%{prompt: "hello", session_id: "session-1"})

    assert {:error, _} = RunRequest.new(%{})
    assert_raise ArgumentError, ~r/Invalid Jido.Harness.RunRequest/, fn -> RunRequest.new!(%{}) end
  end

  test "run_request permission fields default to nil when omitted" do
    assert {:ok,
            %RunRequest{
              disallowed_tools: nil,
              add_dirs: nil,
              mcp_config: nil,
              permission_mode: nil
            }} = RunRequest.new(%{prompt: "hello"})
  end

  test "run_request permission fields round-trip when set" do
    attrs = %{
      prompt: "hello",
      allowed_tools: ["Read", "Edit"],
      disallowed_tools: ["Bash(rm *)", "Bash(curl *)"],
      add_dirs: ["/tmp", "/var/log"],
      mcp_config: %{"servers" => %{"github" => %{"command" => "github-mcp"}}},
      permission_mode: :plan
    }

    assert {:ok, request} = RunRequest.new(attrs)
    assert request.allowed_tools == ["Read", "Edit"]
    assert request.disallowed_tools == ["Bash(rm *)", "Bash(curl *)"]
    assert request.add_dirs == ["/tmp", "/var/log"]
    assert request.mcp_config == %{"servers" => %{"github" => %{"command" => "github-mcp"}}}
    assert request.permission_mode == :plan
  end

  test "run_request permission_mode accepts string variants" do
    assert {:ok, %RunRequest{permission_mode: "accept_edits"}} =
             RunRequest.new(%{prompt: "hello", permission_mode: "accept_edits"})
  end

  test "run_request disallowed_tools rejects non-string elements" do
    assert {:error, _} =
             RunRequest.new(%{prompt: "hello", disallowed_tools: [:not_a_string]})
  end

  test "run_request add_dirs rejects non-string elements" do
    assert {:error, _} = RunRequest.new(%{prompt: "hello", add_dirs: [123]})
  end

  test "run_request new! accepts the full permission set" do
    request =
      RunRequest.new!(%{
        prompt: "hello",
        disallowed_tools: ["Bash(rm *)"],
        add_dirs: ["/tmp"],
        mcp_config: %{"foo" => "bar"},
        permission_mode: :bypass_permissions
      })

    assert request.disallowed_tools == ["Bash(rm *)"]
    assert request.add_dirs == ["/tmp"]
    assert request.mcp_config == %{"foo" => "bar"}
    assert request.permission_mode == :bypass_permissions
  end

  test "event schema constructors validate inputs" do
    assert is_struct(Event.schema())

    assert {:ok, %Event{type: :session_started}} =
             Event.new(%{
               type: :session_started,
               provider: :codex,
               timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
             })

    assert %Event{type: :session_started} =
             Event.new!(%{
               type: :session_started,
               provider: :codex,
               timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
             })

    assert {:error, _} = Event.new(%{})
    assert_raise ArgumentError, ~r/Invalid Jido.Harness.Event/, fn -> Event.new!(%{}) end
  end

  test "provider schema constructors validate inputs" do
    assert is_struct(Provider.schema())
    assert {:ok, %Provider{id: :codex}} = Provider.new(%{id: :codex, name: "Codex"})
    assert %Provider{id: :codex} = Provider.new!(%{id: :codex, name: "Codex"})
    assert {:error, _} = Provider.new(%{name: "Missing ID"})
    assert_raise ArgumentError, ~r/Invalid Jido.Harness.Provider/, fn -> Provider.new!(%{name: "Missing ID"}) end
  end

  test "runtime_contract schema constructors validate inputs" do
    assert is_struct(RuntimeContract.schema())

    assert {:ok, %RuntimeContract{provider: :claude}} =
             RuntimeContract.new(%{provider: :claude})

    assert %RuntimeContract{provider: :codex} =
             RuntimeContract.new!(%{
               provider: :codex,
               runtime_tools_required: ["codex"]
             })

    assert {:error, _} = RuntimeContract.new(%{})

    assert_raise ArgumentError, ~r/Invalid Jido.Harness.RuntimeContract/, fn ->
      RuntimeContract.new!(%{})
    end
  end

  test "error helper constructors build typed exceptions" do
    assert %Error.InvalidInputError{field: :provider} = Error.validation_error("bad provider", %{field: :provider})

    assert %Error.ExecutionFailureError{details: %{provider: :codex}} =
             Error.execution_error("boom", %{provider: :codex})
  end
end
