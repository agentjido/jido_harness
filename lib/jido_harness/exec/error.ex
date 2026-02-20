defmodule Jido.Harness.Exec.Error do
  @moduledoc false

  alias Jido.Harness.Error

  @spec invalid(String.t(), map()) :: Exception.t()
  def invalid(message, details \\ %{}) when is_binary(message) and is_map(details) do
    Error.validation_error(message, details)
  end

  @spec execution(String.t(), map()) :: Exception.t()
  def execution(message, details \\ %{}) when is_binary(message) and is_map(details) do
    Error.execution_error(message, details)
  end
end
