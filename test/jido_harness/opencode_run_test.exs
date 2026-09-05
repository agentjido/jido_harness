defmodule Jido.Harness.OpenCodeRunTest do
  use ExUnit.Case, async: false

  import Jido.Harness.TestHelpers
  alias Jido.Harness.Adapters.{JSONMapper, OpenCode}

  setup context do
    journal_dir = Path.join(System.tmp_dir!(), "harness-opencode-#{System.unique_integer([:positive])}")
    configure_test_provider(Map.put(context, :journal_dir, journal_dir))
    Application.put_env(:jido_harness, :providers, %{opencode: OpenCode})
    Application.put_env(:jido_harness, :provider_config, %{opencode: %{retention: %{journal_dir: journal_dir}}})
    File.mkdir_p!(journal_dir)
    %{argv_path: Path.join(journal_dir, "argv.json")}
  end

  test "captures OpenCode sessionID and resumes the next finite run", %{argv_path: argv_path} do
    options = [
      env: %{"HARNESS_FIXTURE_ARGV" => argv_path},
      provider_options: %{cli_path: fixture_path("fake_opencode_run.py")},
      await_timeout: 5_000
    ]

    assert {:ok, first} = Jido.Harness.run(:opencode, "first", options)
    assert first.status == :completed
    assert first.provider_session_id == "ses_fixture"
    assert {:ok, events} = Jido.Harness.Run.replay(first.run_id)
    assert Enum.any?(events, &(&1.provider_session_id == "ses_fixture"))
    refute "--session" in Jason.decode!(File.read!(argv_path))

    assert {:ok, second} =
             Jido.Harness.run(
               :opencode,
               "second",
               Keyword.put(options, :provider_session_id, first.provider_session_id)
             )

    assert second.status == :completed
    assert second.provider_session_id == first.provider_session_id
    argv = Jason.decode!(File.read!(argv_path))
    assert Enum.at(argv, Enum.find_index(argv, &(&1 == "--session")) + 1) == first.provider_session_id
    assert OpenCode.spec().capabilities.resume?
  end

  test "retains all supported session identifier keys" do
    for key <- [:session_id, :sessionId, :sessionID, :thread_id, :threadId],
        form <- [key, Atom.to_string(key)] do
      event = JSONMapper.map(:opencode, %{form => "session", "type" => "step_start"})
      assert event.provider_session_id == "session"
    end
  end
end
