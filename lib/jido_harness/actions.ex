require Jido.Harness.Action.Definition

Jido.Harness.Action.Definition.define(
  Jido.Harness.Action.Run.Start,
  "harness_run_start",
  Jido.Harness.Signal.Command.Run.Start,
  Jido.Harness.Directive.Run.Start
)

Jido.Harness.Action.Definition.define(
  Jido.Harness.Action.Run.Cancel,
  "harness_run_cancel",
  Jido.Harness.Signal.Command.Run.Cancel,
  Jido.Harness.Directive.Run.Cancel
)

Jido.Harness.Action.Definition.define(
  Jido.Harness.Action.Run.Prune,
  "harness_run_prune",
  Jido.Harness.Signal.Command.Run.Prune,
  Jido.Harness.Directive.Run.Prune
)

Jido.Harness.Action.Definition.define(
  Jido.Harness.Action.Session.Start,
  "harness_session_start",
  Jido.Harness.Signal.Command.Session.Start,
  Jido.Harness.Directive.Session.Start
)

Jido.Harness.Action.Definition.define(
  Jido.Harness.Action.Session.SendMessage,
  "harness_session_send_message",
  Jido.Harness.Signal.Command.Session.SendMessage,
  Jido.Harness.Directive.Session.SendMessage
)

Jido.Harness.Action.Definition.define(
  Jido.Harness.Action.Session.FollowUp,
  "harness_session_follow_up",
  Jido.Harness.Signal.Command.Session.FollowUp,
  Jido.Harness.Directive.Session.FollowUp
)

Jido.Harness.Action.Definition.define(
  Jido.Harness.Action.Session.Steer,
  "harness_session_steer",
  Jido.Harness.Signal.Command.Session.Steer,
  Jido.Harness.Directive.Session.Steer
)

Jido.Harness.Action.Definition.define(
  Jido.Harness.Action.Session.Interrupt,
  "harness_session_interrupt",
  Jido.Harness.Signal.Command.Session.Interrupt,
  Jido.Harness.Directive.Session.Interrupt
)

Jido.Harness.Action.Definition.define(
  Jido.Harness.Action.Session.RespondApproval,
  "harness_session_respond_approval",
  Jido.Harness.Signal.Command.Session.RespondApproval,
  Jido.Harness.Directive.Session.RespondApproval
)

Jido.Harness.Action.Definition.define(
  Jido.Harness.Action.Session.Configure,
  "harness_session_configure",
  Jido.Harness.Signal.Command.Session.Configure,
  Jido.Harness.Directive.Session.Configure
)

Jido.Harness.Action.Definition.define(
  Jido.Harness.Action.Session.Close,
  "harness_session_close",
  Jido.Harness.Signal.Command.Session.Close,
  Jido.Harness.Directive.Session.Close
)

Jido.Harness.Action.Definition.define(
  Jido.Harness.Action.Session.Kill,
  "harness_session_kill",
  Jido.Harness.Signal.Command.Session.Kill,
  Jido.Harness.Directive.Session.Kill
)

Jido.Harness.Action.Definition.define(
  Jido.Harness.Action.Session.Prune,
  "harness_session_prune",
  Jido.Harness.Signal.Command.Session.Prune,
  Jido.Harness.Directive.Session.Prune
)
