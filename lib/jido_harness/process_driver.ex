defmodule Jido.Harness.ProcessDriver do
  @moduledoc false
  alias Jido.Harness.ProcessSpec

  @callback start(ProcessSpec.t(), pid()) :: {:ok, pid(), pos_integer()} | {:error, term()}
  @callback send_input(pid() | pos_integer(), binary() | :eof) :: :ok | {:error, term()}
  @callback signal(pid() | pos_integer(), atom()) :: :ok | {:error, term()}
end
