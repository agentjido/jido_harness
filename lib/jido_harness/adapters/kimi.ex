defmodule Jido.Harness.Adapters.Kimi do
  @moduledoc "Official Kimi Code CLI adapter using non-interactive stream-json output."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.CLIStream, Adapters.Helpers, Capabilities, Error, RunRequest}

  @provider_options [:cli_path, :continue, :skills_dirs, :extra_args]
  @reserved_args [
    "-p",
    "--prompt",
    "--output-format",
    "-m",
    "--model",
    "-S",
    "--session",
    "-r",
    "--resume",
    "-c",
    "--continue",
    "-C",
    "--add-dir",
    "--skills-dir",
    "-y",
    "--yolo",
    "--yes",
    "--auto-approve",
    "--auto",
    "--plan",
    "-V",
    "--version"
  ]

  @impl true
  def spec do
    %AdapterSpec{
      provider: :kimi,
      name: "Kimi Code",
      executable: "kimi",
      docs_url: "https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-command.html",
      capabilities: %Capabilities{
        streaming?: true,
        tool_calls?: true,
        tool_results?: true,
        resume?: true,
        native_cancel?: true
      },
      normalized_options: [
        :model,
        :session_id,
        :add_dirs,
        :approval_mode,
        :sandbox_mode,
        :reasoning_effort
      ],
      normalized_values: %{
        approval_mode: [:default],
        sandbox_mode: [:default]
      },
      provider_options: @provider_options,
      install: %{npm: "@moonshot-ai/kimi-code"}
    }
  end

  @impl true
  def run(%RunRequest{} = request, context) do
    options = Helpers.provider_options(request.provider_options, @provider_options)

    with :ok <- validate_options(request, options),
         {:ok, request} <- prepare_request(request),
         {:ok, argv} <- build_argv(request, options) do
      executable = options[:cli_path] || Helpers.cli_path(context.config, spec().executable)
      CLIStream.run(:kimi, request, context, executable, argv, &map_event/1)
    end
  end

  @impl true
  def status(config),
    do: Helpers.status(:kimi, spec().executable, ["KIMI_MODEL_API_KEY"], config, capabilities: spec().capabilities)

  @impl true
  def install(_config, options), do: Helpers.install_npm(:kimi, "@moonshot-ai/kimi-code", options)

  @impl true
  def cancel(run_id, _context), do: Helpers.cancel_cli_run(run_id)

  @doc false
  def build_argv(request, options) do
    with {:ok, skills_dirs} <- string_list(options[:skills_dirs], :skills_dirs),
         {:ok, extra_args} <- extra_args(options[:extra_args]) do
      argv =
        ["-p", request.prompt, "--output-format", "stream-json"] ++
          model_args(request) ++
          pair("--session", request.session_id) ++
          repeat("--add-dir", request.add_dirs) ++
          repeat("--skills-dir", skills_dirs) ++
          flag("--continue", options[:continue]) ++ extra_args

      {:ok, argv}
    end
  end

  @doc false
  def map_event(%{"role" => "assistant"} = raw) do
    text_events =
      case Map.get(raw, "content") do
        text when is_binary(text) and text != "" ->
          [Helpers.event(:kimi, :output_text_delta, nil, %{"text" => text}, raw)]

        _ ->
          []
      end

    tool_events =
      raw
      |> Map.get("tool_calls", [])
      |> List.wrap()
      |> Enum.flat_map(&tool_call_event(&1, raw))

    case text_events ++ tool_events do
      [] -> [provider_event(raw, %{"role" => "assistant", "mapped" => false})]
      events -> events
    end
  end

  def map_event(%{"role" => "tool"} = raw) do
    [
      Helpers.event(
        :kimi,
        :tool_result,
        nil,
        %{
          "call_id" => Map.get(raw, "tool_call_id"),
          "output" => Map.get(raw, "content"),
          "is_error" => Map.get(raw, "is_error", false)
        },
        raw
      )
    ]
  end

  def map_event(%{"role" => "meta", "type" => "session.resume_hint"} = raw) do
    session_id = Map.get(raw, "session_id")

    [
      Helpers.event(
        :kimi,
        :provider_event,
        session_id,
        %{
          "type" => "session.resume_hint",
          "command" => Map.get(raw, "command"),
          "content" => Map.get(raw, "content")
        },
        raw
      )
    ]
  end

  def map_event(%{"role" => "meta"} = raw),
    do: [provider_event(raw, %{"type" => Map.get(raw, "type"), "mapped" => false})]

  def map_event(raw) when is_map(raw),
    do: [provider_event(raw, %{"mapped" => false, "role" => Map.get(raw, "role")})]

  def map_event(raw),
    do: [provider_event(raw, %{"mapped" => false, "value_type" => value_type(raw)})]

  @doc false
  def prepare_request(%RunRequest{} = request) do
    env_name = request.env["KIMI_MODEL_NAME"] || System.get_env("KIMI_MODEL_NAME")
    requested_name = request.model || env_name
    api_key = request.env["KIMI_MODEL_API_KEY"] || System.get_env("KIMI_MODEL_API_KEY")

    cond do
      present?(env_name) and not present?(api_key) ->
        {:error,
         Error.validation("KIMI_MODEL_NAME requires KIMI_MODEL_API_KEY",
           provider: :kimi,
           details: %{field: :env}
         )}

      present?(api_key) and present?(requested_name) ->
        {:ok, %{request | env: managed_env(request, requested_name, api_key)}}

      present?(request.env["KIMI_MODEL_API_KEY"]) ->
        {:error,
         Error.validation("KIMI_MODEL_API_KEY requires a model or KIMI_MODEL_NAME",
           provider: :kimi,
           details: %{field: :env}
         )}

      true ->
        {:ok, %{request | env: managed_env(request, nil, nil)}}
    end
  end

  defp managed_env(%RunRequest{} = request, model_name, api_key) do
    request.env
    |> Map.put("KIMI_CODE_NO_AUTO_UPDATE", "1")
    |> Map.put("KIMI_DISABLE_CRON", "1")
    |> Map.put("KIMI_CODE_BACKGROUND_KEEP_ALIVE_ON_EXIT", "0")
    |> maybe_put("KIMI_MODEL_NAME", model_name)
    |> maybe_put("KIMI_MODEL_API_KEY", api_key)
    |> maybe_put("KIMI_MODEL_THINKING_EFFORT", request.reasoning_effort)
  end

  defp validate_options(%{session_id: session_id}, %{continue: true}) when is_binary(session_id),
    do: {:error, Error.validation("Kimi session_id and provider continue cannot be combined", provider: :kimi)}

  defp validate_options(_request, _options), do: :ok

  defp tool_call_event(%{"id" => id, "function" => function}, raw) when is_map(function) do
    [
      Helpers.event(
        :kimi,
        :tool_call,
        nil,
        %{
          "call_id" => id,
          "name" => Map.get(function, "name"),
          "input" => decode_arguments(Map.get(function, "arguments"))
        },
        raw
      )
    ]
  end

  defp tool_call_event(value, raw),
    do: [provider_event(raw, %{"mapped" => false, "tool_call" => Helpers.stringify_keys(value)})]

  defp decode_arguments(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> value
    end
  end

  defp decode_arguments(nil), do: %{}
  defp decode_arguments(value), do: Helpers.stringify_keys(value)

  defp provider_event(raw, payload), do: Helpers.event(:kimi, :provider_event, nil, payload, raw)

  defp extra_args(nil), do: {:ok, []}

  defp extra_args(args) when is_list(args) do
    cond do
      not Enum.all?(args, &is_binary/1) ->
        extra_args(:invalid)

      shadow = Enum.find(args, &reserved_arg?(&1, @reserved_args)) ->
        {:error,
         Error.validation("Kimi extra_args cannot shadow managed options",
           provider: :kimi,
           details: %{argument: shadow}
         )}

      true ->
        {:ok, args}
    end
  end

  defp extra_args(_args),
    do: {:error, Error.validation("Kimi extra_args must be a list of strings", provider: :kimi)}

  defp string_list(nil, _field), do: {:ok, []}

  defp string_list(values, field) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: {:ok, values}, else: string_list(:invalid, field)
  end

  defp string_list(_values, field),
    do: {:error, Error.validation("Kimi #{field} must be a list of strings", provider: :kimi)}

  defp flag(flag, true), do: [flag]
  defp flag(_flag, _value), do: []

  defp model_args(%{env: %{"KIMI_MODEL_NAME" => name, "KIMI_MODEL_API_KEY" => key}})
       when is_binary(name) and name != "" and is_binary(key) and key != "",
       do: []

  defp model_args(request), do: pair("--model", request.model)
  defp pair(_flag, nil), do: []
  defp pair(flag, value), do: [flag, to_string(value)]
  defp repeat(_flag, nil), do: []
  defp repeat(flag, values), do: Enum.flat_map(values, &pair(flag, &1))
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, to_string(value))
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp reserved_arg?(argument, reserved) do
    argument in reserved or Enum.any?(reserved, &String.starts_with?(argument, &1 <> "="))
  end

  defp value_type(value) when is_atom(value), do: "atom"
  defp value_type(value) when is_binary(value), do: "string"
  defp value_type(value) when is_list(value), do: "list"
  defp value_type(value) when is_number(value), do: "number"
  defp value_type(_value), do: "other"
end
