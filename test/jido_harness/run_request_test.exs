defmodule Jido.Harness.RunRequestTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.{Error, RunRequest}

  test "normalizes string keys and validates the existing workspace" do
    assert {:ok, request} =
             RunRequest.new(%{
               "prompt" => "hello",
               "cwd" => File.cwd!(),
               "approval_mode" => :prompt,
               "runtime_timeout_ms" => :infinity
             })

    assert request.prompt == "hello"
    assert request.approval_mode == :prompt
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

  test "rejects invalid workspaces and timeouts before execution" do
    assert {:error, %Error{category: :validation}} =
             RunRequest.new(prompt: "hello", cwd: Path.join(System.tmp_dir!(), "missing-jido-harness-cwd"))

    assert {:error, %Error{category: :validation}} =
             RunRequest.new(prompt: "hello", runtime_timeout_ms: 0)

    assert {:error, %Error{category: :validation}} =
             RunRequest.new(prompt: "hello", max_turns: 0)

    assert {:error, %Error{category: :validation}} =
             RunRequest.new(prompt: "hello", provider_options: nil)
  end
end
