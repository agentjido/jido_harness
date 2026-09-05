defmodule Jido.Harness.Adapter do
  @moduledoc "Behaviour implemented by built-in and custom harness providers."

  alias Jido.Harness.{AdapterSpec, ProviderStatus, SessionRequest}

  @type context :: %{
          required(:run_id) => String.t(),
          required(:provider) => atom(),
          required(:config) => map(),
          required(:telemetry_context) => map(),
          required(:process_manager) => module(),
          optional(:run_owner) => pid()
        }

  @callback spec() :: AdapterSpec.t()
  @callback status(map()) :: {:ok, ProviderStatus.t()} | {:error, term()}
  @callback install(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback acp_env(SessionRequest.t(), map()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks install: 2, acp_env: 2
end
