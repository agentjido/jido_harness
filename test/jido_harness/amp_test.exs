defmodule Jido.Harness.FakeAmpCLIRunner do
  @moduledoc false
  @behaviour Jido.Harness.Amp.CLI

  @impl true
  def run(argv, config) do
    send(self(), {:amp_cli, argv, config})
    Process.get(:amp_cli_result, {:error, Jido.Harness.Error.execution("missing fake Amp CLI result")})
  end
end

defmodule Jido.Harness.AmpTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.{Amp, Error}
  alias Jido.Harness.Amp.{CLI, CLIConfig, Orb, OrbRequest, Status}

  @environment ~w(
    AMP_API_KEY
    AMP_CLI_PATH
    AMP_URL
    JIDO_HARNESS_AMP_CWD
    JIDO_HARNESS_AMP_FEATURES
    JIDO_HARNESS_AMP_LABELS
    JIDO_HARNESS_AMP_MAX_OUTPUT_BYTES
    JIDO_HARNESS_AMP_MODE
    JIDO_HARNESS_AMP_ORB_PROVIDER
    JIDO_HARNESS_AMP_ORB_SIZE
    JIDO_HARNESS_AMP_PROFILE
    JIDO_HARNESS_AMP_PROJECT
    JIDO_HARNESS_AMP_TIMEOUT_MS
    JIDO_HARNESS_AMP_VISIBILITY
  )

  setup do
    original_runner = Application.get_env(:jido_harness, :amp_cli_runner)
    original_environment = Map.new(@environment, &{&1, System.get_env(&1)})

    Enum.each(@environment, &System.delete_env/1)
    System.put_env("AMP_API_KEY", "sgamp_test_secret")
    System.put_env("AMP_CLI_PATH", "/bin/echo")
    Application.put_env(:jido_harness, :amp_cli_runner, Jido.Harness.FakeAmpCLIRunner)

    on_exit(fn ->
      if is_nil(original_runner),
        do: Application.delete_env(:jido_harness, :amp_cli_runner),
        else: Application.put_env(:jido_harness, :amp_cli_runner, original_runner)

      Enum.each(original_environment, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "reports stateless Orb-control readiness from the environment" do
    System.put_env("AMP_URL", "https://team.ampcode.app/")
    System.put_env("JIDO_HARNESS_AMP_PROJECT", "acme/widgets")
    System.put_env("JIDO_HARNESS_AMP_ORB_SIZE", "a1.large")
    System.put_env("JIDO_HARNESS_AMP_VISIBILITY", "private")
    System.put_env("JIDO_HARNESS_AMP_LABELS", "managed, release")

    assert {:ok,
            %Status{
              installed: true,
              authenticated: true,
              ready: true,
              executable: "/bin/echo",
              service_url: "https://team.ampcode.app/",
              project: "acme/widgets",
              orb_size: "a1.large",
              visibility: :private,
              labels: ["managed", "release"]
            }} = Amp.status()
  end

  test "rejects a short-lived or malformed token for stateless control" do
    System.put_env("AMP_API_KEY", "short-lived-session-token")

    assert {:ok, %Status{installed: true, authenticated: false, ready: false}} = Amp.status()
    assert {:error, %Error{category: :configuration, message: message}} = Amp.list_threads()
    assert message =~ "sgamp_"
  end

  test "starts an asynchronous Orb with environment defaults and explicit overrides" do
    System.put_env("JIDO_HARNESS_AMP_PROJECT", "acme/widgets")
    System.put_env("JIDO_HARNESS_AMP_MODE", "medium")
    System.put_env("JIDO_HARNESS_AMP_FEATURES", "fast")
    System.put_env("JIDO_HARNESS_AMP_LABELS", "managed")
    Process.put(:amp_cli_result, {:ok, "https://ampcode.com/threads/T-test-123\n"})

    assert {:ok, %Orb{thread_id: "T-test-123", url: "https://ampcode.com/threads/T-test-123"}} =
             Amp.start_orb("Run the release checks",
               orb_size: "a1.large",
               title: "Release checks",
               visibility: :private
             )

    assert_receive {:amp_cli, argv, %CLIConfig{cli_path: "/bin/echo", timeout_ms: 60_000}}

    assert argv == [
             "--no-color",
             "--no-notifications",
             "--no-ide",
             "--no-archive-after-execute",
             "-ox",
             "Run the release checks",
             "--project",
             "acme/widgets",
             "--orb-size",
             "a1.large",
             "--title",
             "Release checks",
             "--mode",
             "medium",
             "--visibility",
             "private",
             "--features",
             "fast",
             "--label",
             "managed"
           ]
  end

  test "continues an Orb by URL and returns the same thread reference" do
    Process.put(:amp_cli_result, {:ok, "https://ampcode.com/threads/T-existing-456\n"})

    assert {:ok, %Orb{thread_id: "T-existing-456"}} =
             Amp.continue_orb(
               "https://ampcode.com/threads/T-existing-456",
               "Check the deployment",
               labels: ["deploy"],
               attachments: ["/tmp/report.txt"]
             )

    assert_receive {:amp_cli, argv, %CLIConfig{}}

    assert argv == [
             "--no-color",
             "--no-notifications",
             "--no-ide",
             "--no-archive-after-execute",
             "threads",
             "continue",
             "T-existing-456",
             "-ox",
             "Check the deployment",
             "--label",
             "deploy",
             "--attach",
             "/tmp/report.txt"
           ]
  end

  test "lists and exports thread JSON without imposing an undocumented provider schema" do
    Process.put(:amp_cli_result, {:ok, ~s([{"id":"T-one","title":"First"}])})

    assert {:ok, [%{"id" => "T-one", "title" => "First"}]} =
             Amp.list_threads(include_archived: true, limit: 25, offset: 5)

    assert_receive {:amp_cli,
                    [
                      "--no-color",
                      "--no-notifications",
                      "--no-ide",
                      "threads",
                      "list",
                      "--json",
                      "--include-archived",
                      "--limit",
                      "25",
                      "--offset",
                      "5"
                    ], %CLIConfig{}}

    Process.put(:amp_cli_result, {:ok, ~s({"id":"T-one","messages":[]})})
    assert {:ok, %{"id" => "T-one", "messages" => []}} = Amp.export_thread("T-one")

    assert_receive {:amp_cli, ["--no-color", "--no-notifications", "--no-ide", "threads", "export", "T-one"],
                    %CLIConfig{}}
  end

  test "archives, restores, and explicitly deletes through thread commands" do
    Process.put(:amp_cli_result, {:ok, "ok\n"})

    assert :ok = Amp.archive_thread("T-one")
    assert_receive {:amp_cli, argv, %CLIConfig{}}
    assert List.last(argv) == "T-one"
    assert Enum.take(argv, -3) == ["threads", "archive", "T-one"]

    assert :ok = Amp.unarchive_thread("T-one")
    assert_receive {:amp_cli, argv, %CLIConfig{}}
    assert Enum.take(argv, -4) == ["threads", "archive", "T-one", "--unarchive"]

    assert :ok = Amp.delete_thread("T-one")
    assert_receive {:amp_cli, argv, %CLIConfig{}}
    assert Enum.take(argv, -3) == ["threads", "delete", "T-one"]
  end

  test "validates requests, thread references, options, and required access tokens" do
    assert {:ok, %OrbRequest{visibility: :workspace}} =
             OrbRequest.new(%{"prompt" => "Work", "visibility" => "workspace"})

    assert {:error, %Error{category: :validation}} = Amp.start_orb(" ")
    assert {:error, %Error{category: :validation}} = Amp.continue_orb("not-a-thread", "Work")
    assert {:error, %Error{category: :validation}} = Amp.list_threads(limit: 0)
    assert {:error, %Error{category: :validation}} = Amp.archive_thread("T-one", unknown: true)

    System.delete_env("AMP_API_KEY")
    assert {:error, %Error{category: :configuration, message: message}} = Amp.list_threads()
    assert message =~ "AMP_API_KEY"
  end

  test "runs production CLI commands through the managed process layer" do
    Application.put_env(:jido_harness, :amp_cli_runner, CLI)
    assert {:ok, config} = CLIConfig.from_env(timeout_ms: 5_000, max_output_bytes: 1_024)

    assert {:ok, "managed-control\n"} = CLI.run(["managed-control"], config)
  end
end
