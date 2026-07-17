defmodule Jido.Harness.APITest do
  use ExUnit.Case, async: false

  import Jido.Harness.TestHelpers

  alias Jido.Harness.{Error, Run}

  setup context do
    journal_dir = Path.join(System.tmp_dir!(), "jido-harness-api-test-#{System.unique_integer([:positive])}")
    configure_test_provider(Map.put(context, :journal_dir, journal_dir))
    :ok
  end

  test "keeps the root API focused on one-shot runs and provider discovery" do
    assert Jido.Harness.__info__(:functions) == [
             default_provider: 0,
             install: 1,
             install: 2,
             providers: 0,
             run: 1,
             run: 2,
             run: 3,
             status: 1,
             version: 0
           ]
  end

  test "run blocks for a normalized result" do
    assert {:ok, result} = Jido.Harness.run(:test, "ok", await_timeout: 5_000)
    assert result.status == :completed
    assert result.text == "fixture-ok"
    assert String.starts_with?(result.run_id, "run_")
  end

  test "providerless calls use only an explicitly configured default" do
    assert {:error, %Error{category: :configuration}} = Run.start("ok")

    Application.put_env(:jido_harness, :default_provider, :test)

    assert {:ok, result} = Jido.Harness.run("ok", await_timeout: 5_000)
    assert result.provider == :test
  end
end
