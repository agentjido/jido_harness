defmodule Jido.Harness.AdapterContractTest do
  use ExUnit.Case, async: false

  use Jido.Harness.AdapterContract,
    adapter: Jido.Harness.Test.AdapterStub,
    provider: :adapter_stub,
    check_run: true,
    run_request: %{prompt: "contract test", metadata: %{}}
end
