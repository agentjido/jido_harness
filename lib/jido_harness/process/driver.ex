defmodule Jido.Harness.ProcessDriver do
  @moduledoc false
  alias Jido.Harness.ProcessSpec

  @callback start(ProcessSpec.t(), pid()) :: {:ok, pid(), pos_integer()} | {:error, term()}
  @callback send_input(pid() | pos_integer(), binary() | :eof) :: :ok | {:error, term()}
  @callback signal(pid() | pos_integer(), atom()) :: :ok | {:error, term()}

  @doc """
  The driver used when the application configures none (`:process_driver`):
  erlexec, except on Windows, for which erlexec has no native helper.
  """
  @spec default() :: module()
  def default, do: default(:os.type())

  @doc false
  def default({:win32, _name}), do: Jido.Harness.ProcessDriver.Port
  def default(_os), do: Jido.Harness.ProcessDriver.Erlexec
end
