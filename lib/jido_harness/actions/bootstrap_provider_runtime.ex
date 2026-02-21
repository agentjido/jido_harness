defmodule Jido.Harness.Actions.BootstrapProviderRuntime do
  @moduledoc "Bootstrap provider runtime prerequisites in an existing shell session."

  use Jido.Action,
    name: "harness_bootstrap_provider_runtime",
    description: "Bootstrap provider runtime requirements",
    schema: [
      provider: [type: :atom, required: true],
      session_id: [type: :string, required: true],
      opts: [type: :map, default: %{}]
    ]

  alias Jido.Harness.Actions.Helpers
  alias Jido.Harness.Exec.Error
  alias Jido.Harness.Exec.ProviderRuntime

  @impl true
  def run(params, _context) do
    with {:ok, opts} <- Helpers.to_keyword(params.opts || %{}) do
      ProviderRuntime.bootstrap_provider_runtime(
        params.provider,
        params.session_id,
        opts
      )
    else
      {:error, {:invalid_option_key, key}} ->
        {:error, Error.invalid("Unsupported option key for provider runtime bootstrap", %{field: :opts, key: key})}

      {:error, :invalid_options} ->
        {:error, Error.invalid("opts must be a map or keyword list", %{field: :opts})}
    end
  end
end
