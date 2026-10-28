defmodule Jido.Harness.Signal.Command.Run.Start do
  @moduledoc "Requests one finite Harness run."
  use Jido.Signal,
    type: "jido.harness.command.run.start",
    dataschema: "urn:jido:harness:schema:command_run_start:1",
    default_source: "urn:jido:harness:command",
    schema: Jido.Harness.Signal.Command.Schemas.run_start()
end

defmodule Jido.Harness.Signal.Command.Run.Cancel do
  @moduledoc "Requests cancellation of one owned Harness run."
  use Jido.Signal,
    type: "jido.harness.command.run.cancel",
    dataschema: "urn:jido:harness:schema:command_run_cancel:1",
    default_source: "urn:jido:harness:command",
    schema: Jido.Harness.Signal.Command.Schemas.run_resource("run_id")
end

defmodule Jido.Harness.Signal.Command.Run.Prune do
  @moduledoc "Requests removal of one terminal owned Harness run."
  use Jido.Signal,
    type: "jido.harness.command.run.prune",
    dataschema: "urn:jido:harness:schema:command_run_prune:1",
    default_source: "urn:jido:harness:command",
    schema: Jido.Harness.Signal.Command.Schemas.run_resource("run_id")
end

defmodule Jido.Harness.Signal.Command.Session.Start do
  @moduledoc "Requests one interactive Harness session."
  use Jido.Signal,
    type: "jido.harness.command.session.start",
    dataschema: "urn:jido:harness:schema:command_session_start:1",
    default_source: "urn:jido:harness:command",
    schema: Jido.Harness.Signal.Command.Schemas.session_start()
end

defmodule Jido.Harness.Signal.Command.Session.SendMessage do
  @moduledoc "Requests an immediate turn in one owned Harness session."
  use Jido.Signal,
    type: "jido.harness.command.session.send_message",
    dataschema: "urn:jido:harness:schema:command_session_send_message:1",
    default_source: "urn:jido:harness:command",
    schema: Jido.Harness.Signal.Command.Schemas.session_turn()
end

defmodule Jido.Harness.Signal.Command.Session.FollowUp do
  @moduledoc "Queues a turn in one owned Harness session."
  use Jido.Signal,
    type: "jido.harness.command.session.follow_up",
    dataschema: "urn:jido:harness:schema:command_session_follow_up:1",
    default_source: "urn:jido:harness:command",
    schema: Jido.Harness.Signal.Command.Schemas.session_turn()
end

defmodule Jido.Harness.Signal.Command.Session.Steer do
  @moduledoc "Steers the active turn in one owned Harness session."
  use Jido.Signal,
    type: "jido.harness.command.session.steer",
    dataschema: "urn:jido:harness:schema:command_session_steer:1",
    default_source: "urn:jido:harness:command",
    schema: Jido.Harness.Signal.Command.Schemas.session_turn()
end

defmodule Jido.Harness.Signal.Command.Session.Interrupt do
  @moduledoc "Interrupts a turn in one owned Harness session."
  use Jido.Signal,
    type: "jido.harness.command.session.interrupt",
    dataschema: "urn:jido:harness:schema:command_session_interrupt:1",
    default_source: "urn:jido:harness:command",
    schema: Jido.Harness.Signal.Command.Schemas.session_interrupt()
end

defmodule Jido.Harness.Signal.Command.Session.RespondApproval do
  @moduledoc "Responds to one approval request in an owned Harness session."
  use Jido.Signal,
    type: "jido.harness.command.session.respond_approval",
    dataschema: "urn:jido:harness:schema:command_session_respond_approval:1",
    default_source: "urn:jido:harness:command",
    schema: Jido.Harness.Signal.Command.Schemas.session_approval()
end

defmodule Jido.Harness.Signal.Command.Session.Configure do
  @moduledoc "Changes supported configuration for one owned Harness session."
  use Jido.Signal,
    type: "jido.harness.command.session.configure",
    dataschema: "urn:jido:harness:schema:command_session_configure:1",
    default_source: "urn:jido:harness:command",
    schema: Jido.Harness.Signal.Command.Schemas.session_configure()
end

defmodule Jido.Harness.Signal.Command.Session.Close do
  @moduledoc "Gracefully closes one owned Harness session."
  use Jido.Signal,
    type: "jido.harness.command.session.close",
    dataschema: "urn:jido:harness:schema:command_session_close:1",
    default_source: "urn:jido:harness:command",
    schema: Jido.Harness.Signal.Command.Schemas.run_resource("session_id")
end

defmodule Jido.Harness.Signal.Command.Session.Kill do
  @moduledoc "Forcibly cancels one owned Harness session."
  use Jido.Signal,
    type: "jido.harness.command.session.kill",
    dataschema: "urn:jido:harness:schema:command_session_kill:1",
    default_source: "urn:jido:harness:command",
    schema: Jido.Harness.Signal.Command.Schemas.run_resource("session_id")
end

defmodule Jido.Harness.Signal.Command.Session.Prune do
  @moduledoc "Removes one terminal owned Harness session."
  use Jido.Signal,
    type: "jido.harness.command.session.prune",
    dataschema: "urn:jido:harness:schema:command_session_prune:1",
    default_source: "urn:jido:harness:command",
    schema: Jido.Harness.Signal.Command.Schemas.run_resource("session_id")
end

defmodule Jido.Harness.Signal.Command.Accepted do
  @moduledoc "Reports successful post-commit execution of one Harness command."
  use Jido.Signal,
    type: "jido.harness.command.accepted",
    dataschema: "urn:jido:harness:schema:command_accepted:1",
    default_source: "urn:jido:harness:plugin",
    schema: Jido.Harness.Signal.Command.Schemas.command_result()
end

defmodule Jido.Harness.Signal.Command.Failed do
  @moduledoc "Reports failed post-commit execution of one Harness command."
  use Jido.Signal,
    type: "jido.harness.command.failed",
    dataschema: "urn:jido:harness:schema:command_failed:1",
    default_source: "urn:jido:harness:plugin",
    schema: Jido.Harness.Signal.Command.Schemas.command_failure()
end
