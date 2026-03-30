defmodule Jido.Harness.SessionControl do
  @moduledoc """
  Version marker for the shared Session Control IR.

  Boundary-backed runtimes keep the IR field set stable and carry live
  boundary descriptors or attach metadata under one reserved metadata key
  instead of widening the public structs with sandbox-specific fields.
  """

  @version "session_control/v1"
  @boundary_metadata_key "boundary"

  @doc "Returns the current Session Control schema version."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Returns the reserved metadata key for live boundary descriptor carriage."
  @spec boundary_metadata_key() :: String.t()
  def boundary_metadata_key, do: @boundary_metadata_key
end
