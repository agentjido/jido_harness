defmodule Jido.Harness.ProviderStatus do
  @moduledoc "Readiness and authentication status for a provider."

  alias Jido.Harness.Capabilities

  @enforce_keys [:provider, :installed, :compatible, :authenticated]
  defstruct [
    :provider,
    :version,
    :executable,
    :error,
    installed: false,
    compatible: false,
    authenticated: :unknown,
    smoke_ready: false,
    capabilities: %Capabilities{},
    details: %{}
  ]

  @type t :: %__MODULE__{
          provider: atom(),
          installed: boolean(),
          compatible: boolean(),
          authenticated: boolean() | :unknown,
          smoke_ready: boolean(),
          capabilities: Capabilities.t(),
          version: String.t() | nil,
          executable: String.t() | nil,
          error: term(),
          details: map()
        }

  @spec ready?(t()) :: boolean()
  @doc "Returns whether the provider is installed, compatible, and not known to be unauthenticated."
  def ready?(%__MODULE__{smoke_ready: ready}), do: ready

  @doc false
  def finalize(%__MODULE__{} = status) do
    ready = status.installed and status.compatible and status.authenticated != false
    %{status | smoke_ready: ready}
  end
end
