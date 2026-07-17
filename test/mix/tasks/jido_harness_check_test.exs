defmodule Mix.Tasks.JidoHarness.CheckTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.{AdapterSpec, CLIInventory, Capabilities, Event, ProviderStatus}
  alias Mix.Tasks.JidoHarness.Check

  defmodule MissingAdapter do
    @behaviour Jido.Harness.Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :check_missing,
        name: "Missing check fixture",
        executable: "missing-check-fixture",
        capabilities: %Capabilities{},
        install: %{npm: "missing-check-fixture"},
        docs_url: "https://example.test/missing-check-fixture"
      }
    end

    @impl true
    def status(_config) do
      send(Application.fetch_env!(:jido_harness, :check_task_test_owner), :status_checked)

      {:ok,
       %ProviderStatus{
         provider: :check_missing,
         installed: false,
         compatible: false,
         authenticated: :unknown,
         smoke_ready: false,
         capabilities: spec().capabilities
       }}
    end

    @impl true
    def install(_config, _options) do
      send(Application.fetch_env!(:jido_harness, :check_task_test_owner), :install_called)
      {:ok, %{status: :installed}}
    end

    @impl true
    def run(_request, _context) do
      send(Application.fetch_env!(:jido_harness, :check_task_test_owner), :run_called)
      {:ok, [Event.new!(provider: :check_missing, type: :output_text_final, payload: %{"text" => "ok"})]}
    end
  end

  setup do
    shell = Mix.shell()
    providers = Application.get_env(:jido_harness, :providers, %{})

    Mix.shell(Mix.Shell.Process)
    Application.put_env(:jido_harness, :check_task_test_owner, self())
    Application.put_env(:jido_harness, :providers, Map.put(Map.new(providers), :check_missing, MissingAdapter))
    Mix.Task.reenable("jido_harness.check")

    on_exit(fn ->
      Mix.shell(shell)
      Application.put_env(:jido_harness, :providers, providers)
      Application.delete_env(:jido_harness, :check_task_test_owner)
      Mix.Task.reenable("jido_harness.check")
    end)

    :ok
  end

  test "default operation checks readiness and prints install and testing guidance without live work" do
    assert :ok = Mix.Task.run("jido_harness.check", ["--providers", "check_missing"])

    assert_received :status_checked
    refute_received :install_called
    refute_received :run_called

    output = shell_output()
    assert output =~ "check_missing"
    assert output =~ "npm install --global missing-check-fixture"
    assert output =~ "jido_harness.integration --providers check_missing --profile smoke"
    assert output =~ "may contact providers and incur usage"
  end

  test "provider selection is bounded by registered names and preserves requested order" do
    specs = [MissingAdapter.spec(), Jido.Harness.Adapters.Codex.spec()]

    assert Enum.map(Check.select_providers("codex,check_missing,codex", specs), & &1.provider) == [
             :codex,
             :check_missing
           ]

    assert_raise Mix.Error, ~r/unknown providers: invented/, fn ->
      Check.select_providers("invented", specs)
    end
  end

  test "inventory selection and strict failures are retained by the consolidated task" do
    entries = CLIInventory.entries()

    assert Enum.map(Check.select_tools("goose,claude,goose", entries), & &1.id) == [:goose, :claude]

    assert_raise Mix.Error, ~r/unknown tools: invented/, fn ->
      Check.select_tools("invented", entries)
    end

    rows = [
      row(:current, :current),
      row(:newer, :newer),
      row(:self_updating, :latest),
      row(:old, :outdated),
      row(:missing, :missing)
    ]

    assert Enum.map(Check.strict_inventory_failures(rows), & &1.entry.id) == [:old, :missing]
  end

  test "npm adapter specs produce copyable global installation commands" do
    assert Check.install_command(Jido.Harness.Adapters.Kimi.spec()) ==
             "npm install --global @moonshot-ai/kimi-code"

    assert Check.install_command(Jido.Harness.Adapters.Pi.spec()) ==
             "npm install --global --ignore-scripts @earendil-works/pi-coding-agent"

    assert Check.install_command(%AdapterSpec{
             provider: :manual,
             name: "Manual",
             executable: "manual",
             capabilities: %Capabilities{}
           }) == nil
  end

  defp row(id, status), do: %{entry: %{id: id}, result: %{version_status: status}}

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
