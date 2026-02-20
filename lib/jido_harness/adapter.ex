defmodule Jido.Harness.Adapter do
  @moduledoc "Behaviour that all CLI agent adapters must implement."

  @callback id() :: atom()
  @callback capabilities() :: map()
  @callback run(Jido.Harness.RunRequest.t(), keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}
  @callback cancel(String.t()) :: :ok | {:error, term()}
  @callback runtime_contract() :: Jido.Harness.RuntimeContract.t()

  @optional_callbacks [cancel: 1, runtime_contract: 0]
end
