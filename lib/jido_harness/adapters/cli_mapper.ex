defmodule Jido.Harness.Adapters.CLIMapper do
  @moduledoc false

  alias Jido.Harness.Adapters.CLIMapper.{ClaudeStream, Codex, Gemini}
  alias Jido.Harness.Event

  @doc "Maps an Amp stream-json record."
  @spec amp(term()) :: [Event.t()]
  def amp(event), do: ClaudeStream.map(:amp, event, assistant_text?: true)

  @doc "Maps a Claude stream-json record."
  @spec claude(term()) :: [Event.t()]
  def claude(event), do: ClaudeStream.map(:claude, event)

  @doc "Maps a Codex exec-json record."
  @spec codex(term()) :: [Event.t()]
  def codex(event), do: Codex.map(event)

  @doc "Maps a Gemini stream-json record while carrying its session identifier."
  @spec gemini(term(), String.t() | nil) :: {[Event.t()], String.t() | nil}
  def gemini(event, session_id), do: Gemini.map(event, session_id)
end
