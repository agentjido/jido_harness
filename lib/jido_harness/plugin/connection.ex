defmodule Jido.Harness.Plugin.Connection do
  @moduledoc false

  defstruct [
    :name,
    :provider,
    :default_workspace,
    :defaults,
    :allowed_options,
    :commands,
    :signals,
    :workspaces,
    :__spark_metadata__
  ]
end
