defmodule Jido.Harness.SessionControl do
  @moduledoc """
  Version marker for the shared Session Control IR.
  """

  @version "session_control/v1"

  @doc "Returns the current Session Control schema version."
  @spec version() :: String.t()
  def version, do: @version
end
