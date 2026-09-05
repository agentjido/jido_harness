defmodule Jido.Harness.RunRequestTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.{Error, RunRequest, SessionRequest, TurnRequest}

  test "accepts xhigh in finite, session, and turn request schemas" do
    assert {:ok, %RunRequest{reasoning_effort: :xhigh}} =
             RunRequest.new(prompt: "finite", reasoning_effort: :xhigh)

    assert {:ok, %SessionRequest{reasoning_effort: :xhigh}} =
             SessionRequest.new(reasoning_effort: :xhigh)

    assert {:ok, %TurnRequest{reasoning_effort: :xhigh}} =
             TurnRequest.new(prompt: "turn", reasoning_effort: :xhigh)
  end

  test "normalizes string keys and validates the existing workspace" do
    assert {:ok, request} =
             RunRequest.new(%{
               "prompt" => "hello",
               "cwd" => File.cwd!(),
               "approval_mode" => :prompt,
               "env_mode" => :replace,
               "runtime_timeout_ms" => :infinity
             })

    assert request.prompt == "hello"
    assert request.approval_mode == :prompt
    assert request.env_mode == :replace
    assert request.runtime_timeout_ms == :infinity
  end

  test "accepts atom or string keys in metadata and provider escape hatches" do
    assert {:ok, request} =
             RunRequest.new(%{
               prompt: "hello",
               metadata: %{"source" => "test", job: "review"},
               provider_options: %{"visibility" => "private", mode: "smart"}
             })

    assert request.metadata[:job] == "review"
    assert request.provider_options[:mode] == "smart"
  end

  test "rejects unknown normalized keys" do
    assert {:error, %Error{category: :validation, details: %{key: :mystery}}} =
             RunRequest.new(prompt: "hello", mystery: true)
  end

  test "rejects normalized fields nested in provider_options" do
    assert {:error, %Error{category: :validation}} =
             RunRequest.new(prompt: "hello", provider_options: %{model: "shadow"})
  end

  test "accepts remote workspace paths and rejects malformed paths" do
    cwd = Path.join(System.tmp_dir!(), "missing-harness-#{System.unique_integer([:positive])}")
    refute File.exists?(cwd)
    assert {:ok, %RunRequest{cwd: ^cwd}} = RunRequest.new(prompt: "hello", cwd: cwd)
    assert {:ok, %SessionRequest{cwd: ^cwd}} = SessionRequest.new(cwd: cwd)

    for path <- ["", nil, "/tmp/invalid\0path"] do
      assert {:error, %Error{category: :validation}} = RunRequest.new(prompt: "hello", cwd: path)
      assert {:error, %Error{category: :validation}} = SessionRequest.new(cwd: path)
      assert {:error, %Error{category: :validation}} = Jido.Harness.ProcessSpec.new(executable: "fixture", cwd: path)
    end
  end

  test "rejects invalid timeouts before execution" do
    assert {:error, %Error{category: :validation}} =
             RunRequest.new(prompt: "hello", runtime_timeout_ms: 0)

    assert {:error, %Error{category: :validation}} =
             RunRequest.new(prompt: "hello", max_turns: 0)

    assert {:error, %Error{category: :validation}} =
             RunRequest.new(prompt: "hello", provider_options: nil)

    assert {:error, %Error{category: :validation}} =
             RunRequest.new(prompt: "hello", env_mode: :inherit)
  end
end
