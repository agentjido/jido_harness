defmodule Jido.Harness.Amp.CLIConfig do
  @moduledoc false

  alias Jido.Harness.Error

  @default_timeout_ms 60_000
  @default_max_output_bytes 8 * 1_024 * 1_024

  @schema Zoi.struct(
            __MODULE__,
            %{
              cli_path: Zoi.string(),
              cwd: Zoi.string(),
              timeout_ms: Zoi.integer(),
              max_output_bytes: Zoi.integer()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec from_env(keyword(), boolean()) :: {:ok, t()} | {:error, Error.t()}
  def from_env(options \\ [], require_auth? \\ true) do
    with :ok <- validate_auth(require_auth?),
         {:ok, timeout_ms} <- positive_option(options, :timeout_ms, "JIDO_HARNESS_AMP_TIMEOUT_MS", @default_timeout_ms),
         {:ok, max_output_bytes} <-
           positive_option(
             options,
             :max_output_bytes,
             "JIDO_HARNESS_AMP_MAX_OUTPUT_BYTES",
             @default_max_output_bytes
           ),
         attrs = %{
           cli_path: Keyword.get(options, :cli_path) || present_env("AMP_CLI_PATH") || "amp",
           cwd: Keyword.get(options, :cwd) || present_env("JIDO_HARNESS_AMP_CWD") || File.cwd!(),
           timeout_ms: timeout_ms,
           max_output_bytes: max_output_bytes
         },
         :ok <- validate_paths(attrs),
         {:ok, config} <- parse(attrs) do
      {:ok, config}
    end
  end

  @spec authenticated?() :: boolean()
  def authenticated?, do: access_token?(present_env("AMP_API_KEY"))

  @spec service_url() :: String.t()
  def service_url, do: present_env("AMP_URL") || "https://ampcode.com/"

  @spec command_env() :: map()
  def command_env do
    %{
      "AMP_API_KEY" => System.get_env("AMP_API_KEY"),
      "AMP_URL" => present_env("AMP_URL"),
      "NO_COLOR" => "1"
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp positive_option(options, option, env_name, default) do
    case Keyword.fetch(options, option) do
      {:ok, value} -> positive_integer(value, option)
      :error -> positive_environment(env_name, default)
    end
  end

  defp positive_environment(name, default) do
    case present_env(name) do
      nil ->
        {:ok, default}

      value ->
        case Integer.parse(value) do
          {integer, ""} -> positive_integer(integer, name)
          _other -> configuration_error("#{name} must be a positive integer", %{value: value})
        end
    end
  end

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value, field),
    do: configuration_error("#{field} must be a positive integer", %{value: value})

  defp validate_auth(false), do: :ok

  defp validate_auth(true) do
    case present_env("AMP_API_KEY") do
      nil -> configuration_error("AMP_API_KEY is required for stateless Amp Orb control")
      value -> if access_token?(value), do: :ok, else: configuration_error("AMP_API_KEY must be an sgamp_ access token")
    end
  end

  defp access_token?("sgamp_" <> suffix), do: String.trim(suffix) != ""
  defp access_token?(_value), do: false

  defp validate_paths(%{cli_path: cli_path, cwd: cwd}) do
    cond do
      not (is_binary(cli_path) and String.trim(cli_path) != "") ->
        configuration_error("AMP_CLI_PATH must be a non-empty executable name or path")

      not (is_binary(cwd) and File.dir?(cwd)) ->
        configuration_error("JIDO_HARNESS_AMP_CWD must be an existing directory", %{cwd: cwd})

      true ->
        :ok
    end
  end

  defp parse(attrs) do
    case Zoi.parse(@schema, attrs) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> configuration_error("invalid Amp CLI configuration", %{reason: inspect(reason)})
    end
  end

  defp present_env(name) do
    case System.get_env(name) do
      value when is_binary(value) -> if(String.trim(value) == "", do: nil, else: value)
      _other -> nil
    end
  end

  defp configuration_error(message, details \\ %{}),
    do: {:error, Error.new(:configuration, message, provider: :amp, details: details)}
end
