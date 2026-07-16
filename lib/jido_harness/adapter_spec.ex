defmodule Jido.Harness.AdapterSpec do
  @moduledoc "Static description of a harness adapter."

  alias Jido.Harness.Capabilities

  @enforce_keys [:provider, :name, :executable, :capabilities]
  defstruct [
    :provider,
    :name,
    :executable,
    :install,
    :docs_url,
    capabilities: %Capabilities{},
    normalized_options: [],
    normalized_values: %{},
    provider_options: [],
    request_defaults: %{}
  ]

  @type t :: %__MODULE__{
          provider: atom(),
          name: String.t(),
          executable: String.t(),
          install: map() | nil,
          docs_url: String.t() | nil,
          capabilities: Capabilities.t(),
          normalized_options: [atom()],
          normalized_values: %{optional(atom()) => [term()]},
          provider_options: [atom()],
          request_defaults: map()
        }
end
