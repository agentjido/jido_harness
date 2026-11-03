defmodule Jido.Harness.Amp.Command do
  @moduledoc false

  alias Jido.Harness.Amp.OrbRequest

  @base ["--no-color", "--no-notifications", "--no-ide"]
  @keep_open ["--no-archive-after-execute"]

  @spec start(OrbRequest.t()) :: [String.t()]
  def start(%OrbRequest{} = request) do
    (@base ++ @keep_open ++ ["-ox", request.prompt])
    |> option("--project", request.project)
    |> option("--orb-size", request.orb_size)
    |> option("--orb-provider", request.orb_provider)
    |> option("--profile", request.profile)
    |> option("--title", request.title)
    |> option("--mode", request.mode)
    |> option("--visibility", request.visibility && Atom.to_string(request.visibility))
    |> option("--features", comma_list(request.features))
    |> repeated("--label", request.labels)
    |> repeated("--attach", request.attachments)
  end

  @spec continue(String.t(), String.t(), [String.t()], [String.t()]) :: [String.t()]
  def continue(thread_id, prompt, labels, attachments) do
    (@base ++ @keep_open ++ ["threads", "continue", thread_id, "-ox", prompt])
    |> repeated("--label", labels)
    |> repeated("--attach", attachments)
  end

  @spec list(keyword()) :: [String.t()]
  def list(options) do
    (@base ++ ["threads", "list", "--json"])
    |> flag("--include-archived", Keyword.get(options, :include_archived, false))
    |> option("--limit", integer_option(options[:limit]))
    |> option("--offset", integer_option(options[:offset]))
  end

  @spec export(String.t()) :: [String.t()]
  def export(thread_id), do: @base ++ ["threads", "export", thread_id]

  @spec archive(String.t()) :: [String.t()]
  def archive(thread_id), do: @base ++ ["threads", "archive", thread_id]

  @spec unarchive(String.t()) :: [String.t()]
  def unarchive(thread_id), do: @base ++ ["threads", "archive", thread_id, "--unarchive"]

  @spec delete(String.t()) :: [String.t()]
  def delete(thread_id), do: @base ++ ["threads", "delete", thread_id]

  defp option(argv, _name, nil), do: argv
  defp option(argv, _name, ""), do: argv
  defp option(argv, name, value), do: argv ++ [name, value]

  defp flag(argv, _name, false), do: argv
  defp flag(argv, name, true), do: argv ++ [name]

  defp repeated(argv, name, values),
    do: Enum.reduce(values, argv, fn value, acc -> acc ++ [name, value] end)

  defp comma_list([]), do: nil
  defp comma_list(values), do: Enum.join(values, ",")
  defp integer_option(nil), do: nil
  defp integer_option(value), do: Integer.to_string(value)
end
