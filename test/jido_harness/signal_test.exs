defmodule Jido.Harness.SignalTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.Signal.{
    ProviderBootstrapped,
    ProviderRunCompleted,
    ProviderRunFailed,
    ProviderRunStarted,
    RuntimeValidated,
    WorkspaceProvisioned
  }

  test "workspace provisioned signal is typed and buildable" do
    assert {:ok, signal} = WorkspaceProvisioned.new(%{run_id: "run-1", session_id: "sess-1", provider: :claude})
    assert signal.type == "jido.harness.workspace.provisioned"
  end

  test "runtime validated signal is typed and buildable" do
    assert {:ok, signal} = RuntimeValidated.new(%{provider: :claude, checks: %{ok: true}})
    assert signal.type == "jido.harness.runtime.validated"
  end

  test "provider bootstrapped signal is typed and buildable" do
    assert {:ok, signal} = ProviderBootstrapped.new(%{provider: :claude, bootstrap: %{status: "ok"}})
    assert signal.type == "jido.harness.provider.bootstrapped"
  end

  test "provider run started signal is typed and buildable" do
    assert {:ok, signal} = ProviderRunStarted.new(%{provider: :claude, cwd: "/tmp/repo", command: "claude run"})
    assert signal.type == "jido.harness.provider.run.started"
  end

  test "provider run completed signal is typed and buildable" do
    assert {:ok, signal} = ProviderRunCompleted.new(%{provider: :claude, success: true, event_count: 3})
    assert signal.type == "jido.harness.provider.run.completed"
  end

  test "provider run failed signal is typed and buildable" do
    assert {:ok, signal} = ProviderRunFailed.new(%{provider: :claude, error: "boom"})
    assert signal.type == "jido.harness.provider.run.failed"
  end
end
