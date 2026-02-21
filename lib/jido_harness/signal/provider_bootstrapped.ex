defmodule Jido.Harness.Signal.ProviderBootstrapped do
  @moduledoc """
  Signal emitted when provider bootstrap steps complete.
  """

  use Jido.Signal,
    type: "jido.harness.provider.bootstrapped",
    default_source: "/jido/harness/provider",
    schema: [
      run_id: [type: :string, required: false],
      request_id: [type: :string, required: false],
      session_id: [type: :string, required: false],
      provider: [type: :atom, required: false],
      bootstrap: [type: :map, required: false]
    ]
end
