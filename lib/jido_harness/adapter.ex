defmodule JidoHarness.Adapter do
  @moduledoc "Behaviour that all CLI agent adapters must implement."

  @callback id() :: atom()
  @callback capabilities() :: map()
  @callback run(JidoHarness.RunRequest.t(), keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}
  @callback cancel(String.t()) :: :ok | {:error, term()}

  @optional_callbacks [cancel: 1]
end
