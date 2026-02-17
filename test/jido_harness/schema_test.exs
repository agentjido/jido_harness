defmodule Jido.Harness.SchemaTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.{Error, Event, Provider, RunRequest}

  test "run_request schema constructors validate inputs" do
    assert is_struct(RunRequest.schema())
    assert {:ok, %RunRequest{prompt: "hello"}} = RunRequest.new(%{prompt: "hello"})
    assert %RunRequest{prompt: "hello"} = RunRequest.new!(%{prompt: "hello"})
    assert {:error, _} = RunRequest.new(%{})
    assert_raise ArgumentError, ~r/Invalid Jido.Harness.RunRequest/, fn -> RunRequest.new!(%{}) end
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

  test "error helper constructors build typed exceptions" do
    assert %Error.InvalidInputError{field: :provider} = Error.validation_error("bad provider", %{field: :provider})

    assert %Error.ExecutionFailureError{details: %{provider: :codex}} =
             Error.execution_error("boom", %{provider: :codex})
  end
end
