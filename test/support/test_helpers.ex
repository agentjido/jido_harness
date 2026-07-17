defmodule Jido.Harness.TestHelpers do
  @moduledoc false

  @fixtures_dir Path.expand("fixtures", __DIR__)

  def fixture_path(name), do: Path.join(@fixtures_dir, name)

  def configure_test_provider(context) do
    providers = Application.get_env(:jido_harness, :providers)
    config = Application.get_env(:jido_harness, :provider_config)
    default = Application.get_env(:jido_harness, :default_provider)

    Application.put_env(:jido_harness, :providers, %{test: Jido.Harness.TestAdapter})
    Application.put_env(:jido_harness, :provider_config, %{test: %{retention: %{journal_dir: context.journal_dir}}})
    Application.delete_env(:jido_harness, :default_provider)

    ExUnit.Callbacks.on_exit(fn ->
      restore_env(:providers, providers)
      restore_env(:provider_config, config)
      restore_env(:default_provider, default)
      cleanup_sessions()
      cleanup_runs()
      cleanup_processes()
      File.rm_rf!(context.journal_dir)
    end)

    :ok
  end

  def cleanup_runs do
    Enum.each(Jido.Harness.Run.list(), fn info ->
      unless Jido.Harness.RunInfo.terminal?(info), do: Jido.Harness.Run.cancel(info.run_id)
      Jido.Harness.Run.prune(info.run_id)
    end)
  end

  def cleanup_sessions do
    Enum.each(Jido.Harness.Session.list(), fn info ->
      unless Jido.Harness.SessionInfo.terminal?(info), do: Jido.Harness.Session.close(info.session_id)
      Jido.Harness.Session.prune(info.session_id)
    end)
  end

  def cleanup_processes do
    Enum.each(Jido.Harness.Process.list(), fn info ->
      unless Jido.Harness.ProcessInfo.terminal?(info), do: Jido.Harness.Process.kill(info.process_id)
      _ = Jido.Harness.Process.await(info.process_id, 2_000)
      Jido.Harness.Process.prune(info.process_id)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_harness, key)
  defp restore_env(key, value), do: Application.put_env(:jido_harness, key, value)
end
