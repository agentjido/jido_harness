defmodule Jido.Harness.Signal.ProviderRunFailed do
  @moduledoc """
  Signal emitted when provider stream execution fails.
  """

  use Jido.Signal,
    type: "jido.harness.provider.run.failed",
    default_source: "/jido/harness/provider",
    schema: [
      run_id: [type: :string, required: false],
      request_id: [type: :string, required: false],
      session_id: [type: :string, required: false],
      provider: [type: :atom, required: false],
      error: [type: :any, required: false]
    ]
end
