defmodule JidoHarnessTest do
  use ExUnit.Case

  test "run/3 returns error for unconfigured provider" do
    assert {:error, %JidoHarness.Error.ProviderNotFoundError{provider: :nonexistent}} =
             JidoHarness.run(:nonexistent, "hello")
  end
end
