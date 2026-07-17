defmodule Jido.Harness.Adapters.SDKMapper do
  @moduledoc false

  alias Jido.Harness.Adapters.SDKMapper.{Amp, Claude, Codex, Gemini}

  defdelegate amp(message), to: Amp, as: :map
  defdelegate claude(message), to: Claude, as: :map
  defdelegate codex(event), to: Codex, as: :map
  defdelegate gemini(event, session_id), to: Gemini, as: :map
end
