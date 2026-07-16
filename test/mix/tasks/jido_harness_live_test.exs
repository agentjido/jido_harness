defmodule Mix.Tasks.JidoHarness.LiveTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.{AdapterSpec, Capabilities, Event, ProviderStatus}
  alias Mix.Tasks.JidoHarness.Live

  defmodule MissingAdapter do
    @behaviour Jido.Harness.Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :live_missing,
        name: "Missing live fixture",
        executable: "missing-live-fixture",
        capabilities: %Capabilities{},
        install: %{npm: "missing-live-fixture"},
        docs_url: "https://example.test/missing-live-fixture"
      }
    end

    @impl true
    def status(_config) do
      send(Application.fetch_env!(:jido_harness, :live_task_test_owner), :status_checked)

      {:ok,
       %ProviderStatus{
         provider: :live_missing,
         installed: false,
         compatible: false,
         authenticated: :unknown,
         smoke_ready: false,
         capabilities: spec().capabilities
       }}
    end

    @impl true
    def install(_config, _options) do
      send(Application.fetch_env!(:jido_harness, :live_task_test_owner), :install_called)
      {:ok, %{status: :installed}}
    end

    @impl true
    def run(_request, _context) do
      send(Application.fetch_env!(:jido_harness, :live_task_test_owner), :run_called)
      {:ok, [Event.new!(provider: :live_missing, type: :output_text_final, payload: %{"text" => "ok"})]}
    end
  end

  setup do
    shell = Mix.shell()
    providers = Application.get_env(:jido_harness, :providers, %{})

    Mix.shell(Mix.Shell.Process)
    Application.put_env(:jido_harness, :live_task_test_owner, self())
    Application.put_env(:jido_harness, :providers, Map.put(Map.new(providers), :live_missing, MissingAdapter))
    Mix.Task.reenable("jido_harness.live")

    on_exit(fn ->
      Mix.shell(shell)
      Application.put_env(:jido_harness, :providers, providers)
      Application.delete_env(:jido_harness, :live_task_test_owner)
      Mix.Task.reenable("jido_harness.live")
    end)

    :ok
  end

  test "default operation checks readiness and prints install and live-test guidance without side effects" do
    assert :ok = Mix.Task.run("jido_harness.live", ["--providers", "live_missing"])

    assert_received :status_checked
    refute_received :install_called
    refute_received :run_called

    output = shell_output()
    assert output =~ "live_missing"
    assert output =~ "npm install --global missing-live-fixture"
    assert output =~ "--test --profile smoke"
    assert output =~ "may contact providers and incur usage"
  end

  test "provider selection is bounded by registered names and preserves requested order" do
    specs = [MissingAdapter.spec(), Jido.Harness.Adapters.Codex.spec()]

    assert Enum.map(Live.select_providers("codex,live_missing,codex", specs), & &1.provider) == [
             :codex,
             :live_missing
           ]

    assert_raise Mix.Error, ~r/unknown providers: invented/, fn ->
      Live.select_providers("invented", specs)
    end
  end

  test "npm adapter specs produce copyable global installation commands" do
    assert Live.install_command(Jido.Harness.Adapters.Kimi.spec()) ==
             "npm install --global @moonshot-ai/kimi-code"

    assert Live.install_command(Jido.Harness.Adapters.Pi.spec()) ==
             "npm install --global --ignore-scripts @earendil-works/pi-coding-agent"

    assert Live.install_command(%AdapterSpec{
             provider: :manual,
             name: "Manual",
             executable: "manual",
             capabilities: %Capabilities{}
           }) == nil
  end

  defp shell_output do
    receive_shell([])
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp receive_shell(messages) do
    receive do
      {:mix_shell, _level, [message]} when is_binary(message) -> receive_shell([message | messages])
      _other -> receive_shell(messages)
    after
      0 -> messages
    end
  end
end
