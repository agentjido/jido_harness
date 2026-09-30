defmodule Jido.Harness.Adapters.Antigravity.Authentication do
  @moduledoc false

  alias Jido.Harness.Error

  @doc false
  @spec check(map()) :: {boolean() | :unknown, Error.t() | nil}
  def check(config) do
    env = environment(:overlay, config, %{})
    home = value(env["GEMINI_HOME"]) || Path.join(System.user_home!(), ".gemini")
    path = Path.join(Path.expand(home), "antigravity-acp/settings.json")

    authenticated =
      with {:ok, contents} <- File.read(path),
           {:ok, %{} = settings} <- Jason.decode(contents) do
        selected_authentication(settings, env)
      else
        _invalid -> false
      end

    error =
      if authenticated == false do
        Error.new(:configuration, "Antigravity ACP authentication is not configured",
          provider: :antigravity,
          details: %{settings_path: path, option: "auth.type"}
        )
      end

    {authenticated, error}
  end

  @doc false
  @spec environment(:overlay | :replace, map(), map()) :: map()
  def environment(mode, config, explicit) do
    ambient = if mode == :overlay, do: System.get_env(), else: %{}
    configured = config[:env] || config["env"] || %{}
    ambient |> Map.merge(configured) |> Map.merge(explicit)
  end

  defp selected_authentication(%{"auth" => %{"type" => "gemini-api-key"}}, env),
    do: not is_nil(value(env["GEMINI_API_KEY"]))

  defp selected_authentication(%{"auth" => %{"type" => method}} = settings, env)
       when method in ["agent-platform", "vertex-ai"] do
    cond do
      value(env["GOOGLE_API_KEY"]) -> true
      project_and_location?(settings, env) -> :unknown
      true -> false
    end
  end

  defp selected_authentication(%{"auth" => %{"type" => "oauth-personal"}}, _env), do: :unknown

  defp selected_authentication(%{"auth" => %{"type" => "oauth-business"}} = settings, _env),
    do: if(project_and_location?(settings, %{}), do: :unknown, else: false)

  defp selected_authentication(_settings, _env), do: false

  defp project_and_location?(settings, env) do
    gcp = if is_map(settings["gcp"]), do: settings["gcp"], else: %{}
    project = value(env["GOOGLE_CLOUD_PROJECT"]) || value(gcp["project"])
    location = value(env["GOOGLE_CLOUD_LOCATION"]) || value(gcp["location"])
    not is_nil(project) and not is_nil(location)
  end

  defp value(value) when is_binary(value) do
    if String.trim(value) != "", do: value
  end

  defp value(_value), do: nil
end
