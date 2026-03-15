defmodule Jido.Harness.RuntimeFacadeTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.RunRequest
  alias Jido.Harness.Test.RuntimeBackedAdapterStub

  setup do
    old_providers = Application.get_env(:jido_harness, :providers)
    old_default = Application.get_env(:jido_harness, :default_provider)

    on_exit(fn ->
      restore_env(:jido_harness, :providers, old_providers)
      restore_env(:jido_harness, :default_provider, old_default)
    end)

    :ok
  end

  test "run_request/3 routes runtime-backed adapters through the runtime driver seam" do
    Application.put_env(:jido_harness, :providers, %{runtime_adapter: RuntimeBackedAdapterStub})

    request =
      RunRequest.new!(%{
        prompt: "hello through runtime",
        cwd: "/tmp/runtime-project",
        metadata: %{}
      })

    assert {:ok, stream} = Jido.Harness.run_request(:runtime_adapter, request, transport: :exec)
    events = Enum.to_list(stream)

    assert_receive {:runtime_backed_adapter_start_session, start_opts}
    assert start_opts[:cwd] == "/tmp/runtime-project"
    assert start_opts[:transport] == :exec

    assert_receive {:runtime_backed_adapter_stream_run, "runtime-session-1", ^request, [transport: :exec]}
    refute_receive {:runtime_backed_adapter_legacy_run, _, _}
    assert_receive {:runtime_backed_adapter_stop_session, "runtime-session-1"}

    assert [%Jido.Harness.Event{type: :run_started}, %Jido.Harness.Event{type: :result}] = events
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
