defmodule Jido.Harness.Action do
  @moduledoc "Typed Jido Actions for Harness command Signals."

  @modules [
    Jido.Harness.Action.Run.Start,
    Jido.Harness.Action.Run.Cancel,
    Jido.Harness.Action.Run.Prune,
    Jido.Harness.Action.Session.Start,
    Jido.Harness.Action.Session.SendMessage,
    Jido.Harness.Action.Session.FollowUp,
    Jido.Harness.Action.Session.Steer,
    Jido.Harness.Action.Session.Interrupt,
    Jido.Harness.Action.Session.RespondApproval,
    Jido.Harness.Action.Session.Configure,
    Jido.Harness.Action.Session.Close,
    Jido.Harness.Action.Session.Kill,
    Jido.Harness.Action.Session.Prune
  ]

  @doc "Returns all built-in Harness command Actions."
  @spec modules() :: [module()]
  def modules, do: @modules

  @doc false
  @spec directive_modules() :: [module()]
  def directive_modules, do: Enum.map(@modules, & &1.directive_module())
end
