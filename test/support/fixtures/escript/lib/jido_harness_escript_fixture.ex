defmodule JidoHarnessEscriptFixture do
  def main(_arguments) do
    cache_dir = System.fetch_env!("JIDO_HARNESS_ESCRIPT_CACHE_DIR")
    Application.put_env(:jido_harness, :process_manager, %{journal_dir: Path.join(cache_dir, "journals")})

    with {:ok, helper_path} <- Jido.Harness.Escript.bootstrap_erlexec(cache_dir: cache_dir),
         {:ok, _applications} <- Application.ensure_all_started(:jido_harness) do
      {:ok, env} = Jido.Harness.Adapters.Antigravity.acp_env(Jido.Harness.SessionRequest.new!(%{}), %{})
      true = String.contains?(env["NODE_OPTIONS"], "--import=data:text/javascript;base64,")
      IO.puts("BOOTSTRAP_OK=" <> helper_path)
    else
      {:error, error} ->
        IO.puts(:stderr, Exception.message(error))
        System.halt(1)
    end
  end
end
