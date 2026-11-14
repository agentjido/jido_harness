defmodule Jido.Harness.Amp do
  @moduledoc """
  Stateless control surface for Amp threads that run in Orbs.

  Amp keeps the durable thread and Orb state. Each function runs one short Amp
  CLI command. The caller only needs the Amp CLI and an `AMP_API_KEY` access
  token. `start_orb/2` and `continue_orb/3` return after Amp accepts the work;
  they do not wait for the agent turn to finish. They keep the thread
  unarchived so that the caller can continue it or attach event subscriptions.

  This API is separate from the `:amp` ACP provider. The ACP provider runs an
  Amp session under Harness supervision. This module asks Amp to run the work
  remotely in an Amp-managed Orb.
  """

  alias Jido.Harness.{Error, ProcessSpec, Validation}
  alias Jido.Harness.Amp.{CLI, CLIConfig, Command, Orb, OrbRequest, Status}

  @transport_keys [:cli_path, :cwd, :timeout_ms, :max_output_bytes]
  @continue_keys [:labels, :attachments]
  @list_keys [:include_archived, :limit, :offset]

  @doc "Returns Amp CLI, access-token, and environment-default readiness without starting work."
  @spec status() :: Jido.Harness.result(Status.t())
  def status do
    with {:ok, config} <- CLIConfig.from_env([], false),
         {:ok, defaults} <- request_defaults(),
         executable = resolved_executable(config.cli_path),
         authenticated = CLIConfig.authenticated?() do
      Status.new(%{
        installed: not is_nil(executable),
        authenticated: authenticated,
        ready: not is_nil(executable) and authenticated,
        executable: executable,
        service_url: CLIConfig.service_url(),
        project: defaults.project,
        orb_size: defaults.orb_size,
        orb_provider: defaults.orb_provider,
        profile: defaults.profile,
        mode: defaults.mode,
        visibility: defaults.visibility,
        features: defaults.features,
        labels: defaults.labels
      })
    end
  end

  @doc "Starts one asynchronous Amp Orb thread and returns its stable thread reference."
  @spec start_orb(String.t(), keyword()) :: Jido.Harness.result(Orb.t())
  def start_orb(prompt, options \\ []) do
    with {:ok, request_options, transport_options} <- split_request_options(options),
         {:ok, defaults} <- request_defaults(),
         attrs = defaults |> Map.from_struct() |> Map.merge(Map.new(request_options)),
         {:ok, request} <- OrbRequest.new(Map.put(attrs, :prompt, prompt)),
         {:ok, config} <- CLIConfig.from_env(transport_options),
         {:ok, output} <- CLI.run(Command.start(request), config) do
      parse_orb(output)
    end
  end

  @doc "Sends one asynchronous follow-up message to an existing Amp Orb thread."
  @spec continue_orb(String.t(), String.t(), keyword()) :: Jido.Harness.result(Orb.t())
  def continue_orb(thread, prompt, options \\ []) do
    with {:ok, command_options, transport_options} <- split_options(options, @continue_keys, @transport_keys),
         {:ok, thread_id} <- thread_id(thread),
         :ok <- non_empty(prompt, :prompt),
         {:ok, labels} <-
           string_list(Keyword.get(command_options, :labels, default_list("JIDO_HARNESS_AMP_LABELS")), :labels),
         {:ok, attachments} <- string_list(Keyword.get(command_options, :attachments, []), :attachments),
         {:ok, config} <- CLIConfig.from_env(transport_options),
         {:ok, output} <- CLI.run(Command.continue(thread_id, prompt, labels, attachments), config) do
      parse_orb(output)
    end
  end

  @doc "Lists Amp threads visible to the access token. The result includes local, runner, and Orb threads."
  @spec list_threads(keyword()) :: Jido.Harness.result([map()])
  def list_threads(options \\ []) do
    with {:ok, list_options, transport_options} <- split_options(options, @list_keys, @transport_keys),
         :ok <- validate_list_options(list_options),
         {:ok, config} <- CLIConfig.from_env(transport_options),
         {:ok, output} <- CLI.run(Command.list(list_options), config),
         {:ok, value} <- decode_json(output, "Amp thread list"),
         true <-
           is_list(value) or {:error, Error.new(:provider, "Amp thread list was not a JSON array", provider: :amp)} do
      {:ok, value}
    end
  end

  @doc "Exports the complete JSON document for one Amp thread."
  @spec export_thread(String.t(), keyword()) :: Jido.Harness.result(map())
  def export_thread(thread, options \\ []) do
    with {:ok, [], transport_options} <- split_options(options, [], @transport_keys),
         {:ok, thread_id} <- thread_id(thread),
         {:ok, config} <- CLIConfig.from_env(transport_options),
         {:ok, output} <- CLI.run(Command.export(thread_id), config),
         {:ok, value} <- decode_json(output, "Amp thread export"),
         true <-
           is_map(value) or {:error, Error.new(:provider, "Amp thread export was not a JSON object", provider: :amp)} do
      {:ok, value}
    end
  end

  @doc "Archives one Amp thread. Archiving does not stop work that is already running."
  @spec archive_thread(String.t(), keyword()) :: :ok | {:error, term()}
  def archive_thread(thread, options \\ []), do: thread_command(thread, options, &Command.archive/1)

  @doc "Restores one archived Amp thread."
  @spec unarchive_thread(String.t(), keyword()) :: :ok | {:error, term()}
  def unarchive_thread(thread, options \\ []), do: thread_command(thread, options, &Command.unarchive/1)

  @doc "Permanently deletes one Amp thread."
  @spec delete_thread(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_thread(thread, options \\ []), do: thread_command(thread, options, &Command.delete/1)

  defp thread_command(thread, options, command) do
    with {:ok, [], transport_options} <- split_options(options, [], @transport_keys),
         {:ok, thread_id} <- thread_id(thread),
         {:ok, config} <- CLIConfig.from_env(transport_options),
         {:ok, _output} <- CLI.run(command.(thread_id), config) do
      :ok
    end
  end

  defp split_request_options(options) do
    with {:ok, options} <- Validation.keyword_options(options) do
      {transport_options, request_options} = Keyword.split(options, @transport_keys)
      {:ok, request_options, transport_options}
    end
  end

  defp split_options(options, command_keys, transport_keys) do
    with {:ok, options} <- Validation.keyword_options(options),
         unknown = Keyword.keys(options) -- (command_keys ++ transport_keys),
         :ok <- no_unknown_options(unknown) do
      {transport_options, command_options} = Keyword.split(options, transport_keys)
      {:ok, command_options, transport_options}
    end
  end

  defp no_unknown_options([]), do: :ok

  defp no_unknown_options([key | _rest]),
    do: {:error, Error.validation("unknown Amp control option", details: %{key: key})}

  defp request_defaults do
    OrbRequest.new(%{
      prompt: "environment-default-probe",
      project: present_env("JIDO_HARNESS_AMP_PROJECT"),
      orb_size: present_env("JIDO_HARNESS_AMP_ORB_SIZE"),
      orb_provider: present_env("JIDO_HARNESS_AMP_ORB_PROVIDER"),
      profile: present_env("JIDO_HARNESS_AMP_PROFILE"),
      mode: present_env("JIDO_HARNESS_AMP_MODE"),
      visibility: present_env("JIDO_HARNESS_AMP_VISIBILITY"),
      features: default_list("JIDO_HARNESS_AMP_FEATURES"),
      labels: default_list("JIDO_HARNESS_AMP_LABELS")
    })
  end

  defp validate_list_options(options) do
    include_archived = Keyword.get(options, :include_archived, false)
    limit = Keyword.get(options, :limit)
    offset = Keyword.get(options, :offset)

    cond do
      not is_boolean(include_archived) ->
        {:error, Error.validation("include_archived must be a boolean")}

      not is_nil(limit) and not (is_integer(limit) and limit > 0) ->
        {:error, Error.validation("limit must be a positive integer")}

      not is_nil(offset) and not (is_integer(offset) and offset >= 0) ->
        {:error, Error.validation("offset must be a non-negative integer")}

      true ->
        :ok
    end
  end

  defp parse_orb(output) do
    case Regex.run(~r{(https?://[^\s]+/threads/(T-[A-Za-z0-9_-]+))}, output) do
      [_match, url, thread_id] -> Orb.new(thread_id: thread_id, url: url)
      _other -> {:error, Error.new(:provider, "Amp CLI did not return a thread URL", provider: :amp)}
    end
  end

  defp thread_id(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      Regex.match?(~r/^T-[A-Za-z0-9_-]+$/, value) ->
        {:ok, value}

      match = Regex.run(~r{/threads/(T-[A-Za-z0-9_-]+)}, value) ->
        {:ok, Enum.at(match, 1)}

      true ->
        {:error, Error.validation("Amp thread must be a T- identifier or thread URL")}
    end
  end

  defp thread_id(_value), do: {:error, Error.validation("Amp thread must be a T- identifier or thread URL")}

  defp non_empty(value, field) when is_binary(value) do
    if String.trim(value) == "",
      do: {:error, Error.validation("#{field} must be a non-empty string")},
      else: :ok
  end

  defp non_empty(_value, field), do: {:error, Error.validation("#{field} must be a non-empty string")}

  defp string_list(values, _field)
       when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")),
      do: {:ok, values},
      else: {:error, Error.validation("list values must be non-empty strings")}
  end

  defp string_list(_values, field), do: {:error, Error.validation("#{field} must be a list of strings")}

  defp decode_json(output, name) do
    case Jason.decode(output) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, Error.new(:provider, "#{name} was not valid JSON", provider: :amp, cause: reason)}
    end
  end

  defp resolved_executable(cli_path) do
    case ProcessSpec.resolve_executable(cli_path) do
      {:ok, path} -> path
      {:error, _reason} -> nil
    end
  end

  defp default_list(name) do
    case present_env(name) do
      nil -> []
      value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end
  end

  defp present_env(name) do
    case System.get_env(name) do
      value when is_binary(value) -> if(String.trim(value) == "", do: nil, else: value)
      _other -> nil
    end
  end
end
