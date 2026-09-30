defmodule Jido.Harness.AntigravityTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.Adapters.Antigravity
  alias Jido.Harness.Adapters.Antigravity.Authentication
  alias Jido.Harness.{Error, ProviderStatus, Session, SessionRequest}
  import Jido.Harness.TestHelpers

  setup do
    directory = Path.join(System.tmp_dir!(), "harness-antigravity-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(directory, "antigravity-acp"))
    provider_config = Application.get_env(:jido_harness, :provider_config, %{})
    fixture = fixture_path("antigravity_acp/dist/bin/cli.js")

    config = %{
      cli_path: "/bin/echo",
      acp_path: fixture,
      env: %{
        "GEMINI_HOME" => directory,
        "GEMINI_API_KEY" => nil,
        "GOOGLE_API_KEY" => nil,
        "GOOGLE_CLOUD_PROJECT" => nil,
        "GOOGLE_CLOUD_LOCATION" => nil
      }
    }

    Application.put_env(:jido_harness, :provider_config, Map.put(provider_config, :antigravity, config))

    on_exit(fn ->
      cleanup_runs()
      cleanup_sessions()
      cleanup_processes()
      Application.put_env(:jido_harness, :provider_config, provider_config)
      File.rm_rf!(directory)
    end)

    {:ok, directory: directory, config: config}
  end

  test "API keys alone cannot select authentication", %{config: config} do
    config =
      put_in(config.env, Map.merge(config.env, %{"GEMINI_API_KEY" => "fixture-key", "GOOGLE_API_KEY" => "fixture-key"}))

    assert {:ok, status} = Antigravity.status(config)
    refute status.authenticated
    refute status.smoke_ready
    refute ProviderStatus.ready?(status)
    assert %Error{category: :configuration, details: %{option: "auth.type"}} = status.error
    refute inspect(status) =~ "fixture-key"
  end

  test "authentication matches the selected key source", %{directory: directory, config: config} do
    settings(directory, %{"auth" => %{"type" => "gemini-api-key"}})
    config = put_in(config.env, Map.merge(config.env, %{"GEMINI_API_KEY" => false, "GOOGLE_API_KEY" => "wrong-key"}))
    assert {false, %Error{}} = Authentication.check(config)
    config = put_in(config.env["GEMINI_API_KEY"], "fixture-key")
    assert {true, nil} = Authentication.check(config)

    settings(directory, %{"auth" => %{"type" => "agent-platform"}})
    assert {true, nil} = Authentication.check(config)
    config = put_in(config.env["GOOGLE_API_KEY"], nil)
    assert {false, %Error{}} = Authentication.check(config)

    settings(directory, %{
      "auth" => %{"type" => "vertex-ai"},
      "gcp" => %{"project" => "fixture", "location" => "us-central1"}
    })

    assert {:unknown, nil} = Authentication.check(config)
  end

  test "cached OAuth remains unknown and malformed settings fail", %{directory: directory, config: config} do
    settings(directory, %{"auth" => %{"type" => "oauth-personal"}})
    assert {:unknown, nil} = Authentication.check(config)
    settings(directory, %{"auth" => %{"type" => "oauth-business"}})
    assert {false, %Error{}} = Authentication.check(config)

    settings(directory, %{
      "auth" => %{"type" => "oauth-business"},
      "gcp" => %{"project" => "fixture", "location" => "us"}
    })

    assert {:unknown, nil} = Authentication.check(config)

    for malformed <- [%{"auth" => true}, %{"auth" => %{"type" => "gateway"}}, ["invalid"]] do
      settings(directory, malformed)
      assert {false, %Error{}} = Authentication.check(config)
    end

    File.write!(Path.join(directory, "antigravity-acp/settings.json"), "invalid-json-secret")
    assert {false, error} = Authentication.check(config)
    refute inspect(error) =~ "invalid-json-secret"
  end

  test "the preload preserves explicit Node options and replacement environments" do
    config = %{env: %{"NODE_OPTIONS" => "--no-warnings"}}
    request = SessionRequest.new!(%{env_mode: :replace, env: %{"NODE_OPTIONS" => "--trace-warnings"}})
    assert {:ok, env} = Antigravity.acp_env(request, config)
    assert String.starts_with?(env["NODE_OPTIONS"], "--trace-warnings --import=data:text/javascript;base64,")
    refute env["NODE_OPTIONS"] =~ "--no-warnings"
    request = SessionRequest.new!(%{env_mode: :replace, env: %{"NODE_OPTIONS" => nil}})
    assert {:ok, env} = Antigravity.acp_env(request, config)
    assert String.starts_with?(env["NODE_OPTIONS"], "--import=data:text/javascript;base64,")
  end

  test "a wrapper panic fails the run and preserves partial text" do
    assert {:ok, result} = Jido.Harness.run(:antigravity, "panic", await_timeout: 5_000)
    assert result.status == :failed
    assert result.text == "partial-output"
    assert %Error{message: "Antigravity ACP server crashed during the turn"} = result.error
    assert Enum.count(result.events, &(&1.type == :run_failed)) == 1
    refute Enum.any?(result.events, &(&1.type == :run_completed))
  end

  test "a panic does not turn later valid session responses into errors" do
    assert {:ok, session} = Session.start(:antigravity, %{})
    assert eventually(fn -> match?({:ok, %{state: :idle}}, Session.info(session)) end)
    assert {:ok, turn} = Session.send_message(session, "panic")
    assert {:ok, %{status: :failed}} = Session.await(session, turn, 5_000)
    assert {:ok, turn} = Session.send_message(session, "normal")
    assert {:ok, %{status: :completed, text: "fixture-ok"}} = Session.await(session, turn, 5_000)
  end

  test "the preload fails closed for an untested wrapper version", %{directory: directory, config: config} do
    target = Path.join(directory, "unsupported-wrapper")
    File.cp_r!(fixture_path("antigravity_acp"), target)

    File.write!(
      Path.join(target, "package.json"),
      Jason.encode!(%{name: "@simonepri/refined-antigravity-acp", version: "2.0.0", type: "module"})
    )

    config = %{config | acp_path: Path.join(target, "dist/bin/cli.js")}
    Application.put_env(:jido_harness, :provider_config, %{antigravity: config})
    assert {:ok, result} = Jido.Harness.run(:antigravity, "normal", await_timeout: 5_000)
    assert result.status == :failed
    assert result.error.details.process["stderr"] =~ "requires refined-antigravity-acp 1.2.11"
    refute Enum.any?(result.events, &(&1.type == :output_text_delta))
  end

  test "child Node packages can inherit the preload without being patched", %{directory: directory} do
    child = Path.join(directory, "child-node")
    File.mkdir_p!(child)
    File.write!(Path.join(child, "package.json"), Jason.encode!(%{name: "unrelated-mcp-server", version: "2.0.0"}))
    entry = Path.join(child, "index.js")
    File.write!(entry, "console.log('child-ok')")
    assert {:ok, env} = Antigravity.acp_env(SessionRequest.new!(%{}), %{})
    assert {"child-ok\n", 0} = System.cmd("node", [entry], env: Map.to_list(env), stderr_to_stdout: true)
  end

  @tag :antigravity_wrapper
  test "the actual pinned wrapper fails on a native panic and recovers for the next turn", %{config: config} do
    path = System.fetch_env!("HARNESS_TEST_ANTIGRAVITY_ACP_PATH")
    env = Map.put(config.env, "REFINED_AGY_ACP_BIN", fixture_path("fake_acp_cli.py"))
    config = %{config | acp_path: path, env: env}
    Application.put_env(:jido_harness, :provider_config, %{antigravity: config})
    assert {:ok, session} = Session.start(:antigravity, %{})
    assert eventually(fn -> match?({:ok, %{state: :idle}}, Session.info(session)) end)
    assert {:ok, turn} = Session.send_message(session, "harness-provider-panic")

    assert {:ok, %{status: :failed, error: %Error{message: "Antigravity ACP server crashed during the turn"}}} =
             Session.await(session, turn, 5_000)

    assert {:ok, turn} = Session.send_message(session, "fixture")
    assert {:ok, %{status: :completed, text: "fixture-ok"}} = Session.await(session, turn, 5_000)
  end

  defp settings(directory, value),
    do: File.write!(Path.join(directory, "antigravity-acp/settings.json"), Jason.encode!(value))

  defp eventually(function, attempts \\ 100)
  defp eventually(_function, 0), do: false

  defp eventually(function, attempts) do
    if function.(),
      do: true,
      else:
        (
          Process.sleep(20)
          eventually(function, attempts - 1)
        )
  end
end
