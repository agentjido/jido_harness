defmodule Jido.Harness.ReplayStore.ETS do
  @moduledoc """
  Bounded replay storage in a private ETS ordered set per resource.

  The resource worker owns the table and serializes access. Table ownership
  removes records on worker exit. No additional process is started. Options
  and logical budgets match `Jido.Harness.ReplayStore.Memory`. Close does not
  delete the table; explicit delete or owner exit removes it.
  """
  @behaviour Jido.Harness.ReplayStore
  alias Jido.Harness.ReplayStore.Memory

  @impl true
  defdelegate validate_options(options), to: Memory
  @impl true
  def open(resource, options) do
    with :ok <- Jido.Harness.ReplayStore.validate_resource(resource), do: Memory.create(options, :ets)
  end

  @impl true
  defdelegate append(state, record), to: Memory
  @impl true
  defdelegate read(state, cursor, limits), to: Memory
  @impl true
  defdelegate info(state), to: Memory
  @impl true
  defdelegate close(state), to: Memory
  @impl true
  defdelegate delete(state), to: Memory
end
