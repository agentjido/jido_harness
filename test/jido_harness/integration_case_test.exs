defmodule Jido.Harness.IntegrationCaseTest do
  use ExUnit.Case, async: false

  import Jido.Harness.TestHelpers

  @soak_env [
    "JIDO_HARNESS_LIVE_SOAK_DURATION_MS",
    "JIDO_HARNESS_LIVE_SOAK_INTERVAL_MS",
    "JIDO_HARNESS_LIVE_SOAK_TURN_TIMEOUT_MS",
    "JIDO_HARNESS_LIVE_SOAK_MAX_TURNS"
  ]

  setup context do
    journal_dir = Path.join(System.tmp_dir!(), "jido-harness-integration-case-#{System.unique_integer([:positive])}")
    configure_test_provider(Map.put(context, :journal_dir, journal_dir))
    original = Map.new(@soak_env, &{&1, System.get_env(&1)})

    System.put_env("JIDO_HARNESS_LIVE_SOAK_DURATION_MS", "5000")
    System.put_env("JIDO_HARNESS_LIVE_SOAK_INTERVAL_MS", "1")
    System.put_env("JIDO_HARNESS_LIVE_SOAK_TURN_TIMEOUT_MS", "5000")
    System.put_env("JIDO_HARNESS_LIVE_SOAK_MAX_TURNS", "2")

    on_exit(fn ->
      Enum.each(original, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "live ACP soak keeps one owned session and process across bounded turns" do
    assert %{
             provider: :test,
             protocol: :acp,
             turns: 2,
             provider_session_id: "acp-fixture-session"
           } = Jido.Harness.IntegrationCase.live_soak!(:test)
  end

  test "live soak is selected only by the explicit soak profile" do
    profile = System.get_env("JIDO_HARNESS_INTEGRATION_PROFILE")
    strict = System.get_env("JIDO_HARNESS_INTEGRATION_STRICT")

    on_exit(fn ->
      if profile,
        do: System.put_env("JIDO_HARNESS_INTEGRATION_PROFILE", profile),
        else: System.delete_env("JIDO_HARNESS_INTEGRATION_PROFILE")

      if strict,
        do: System.put_env("JIDO_HARNESS_INTEGRATION_STRICT", strict),
        else: System.delete_env("JIDO_HARNESS_INTEGRATION_STRICT")
    end)

    System.put_env("JIDO_HARNESS_INTEGRATION_STRICT", "true")
    System.put_env("JIDO_HARNESS_INTEGRATION_PROFILE", "contract")
    assert Jido.Harness.IntegrationCase.skip_reason(:test, :soak) == "live soak profile not selected"

    System.put_env("JIDO_HARNESS_INTEGRATION_PROFILE", "soak")
    assert Jido.Harness.IntegrationCase.skip_reason(:test, :soak) == false
  end
end
