defmodule Jido.Harness.TestHelpers do
  @moduledoc false

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
      cleanup_runs()
      cleanup_processes()
      File.rm_rf!(context.journal_dir)
    end)

    :ok
  end

  def cleanup_runs do
    Enum.each(Jido.Harness.list_runs(), fn info ->
      unless Jido.Harness.RunInfo.terminal?(info), do: Jido.Harness.cancel(info.run_id)
      Jido.Harness.prune(info.run_id)
    end)
  end

  def cleanup_processes do
    Enum.each(Jido.Harness.list_processes(), fn info ->
      unless Jido.Harness.ProcessInfo.terminal?(info), do: Jido.Harness.kill_process(info.process_id)
      _ = Jido.Harness.await_process(info.process_id, 2_000)
      Jido.Harness.prune_process(info.process_id)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_harness, key)
  defp restore_env(key, value), do: Application.put_env(:jido_harness, key, value)
end
