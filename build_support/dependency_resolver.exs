defmodule Jido.Harness.Build.DependencyResolver do
  @moduledoc false

  @project_root Path.expand("..", __DIR__)
  @jido_shell_ref "7a99ce9c1b32f305628fb0238dcf2de2fd2e89d7"
  @jido_vfs_ref "0817e6cade2e34dacf6b2e648e86ea14f4a84c84"
  @sprites_ref "07b225e8c1eeb35d1bfc9690e1f2fda5165b2a99"

  def jido_shell(opts \\ []) do
    resolve(
      :jido_shell,
      ["../jido_shell"],
      [github: "nshkrdotcom/jido_shell", ref: @jido_shell_ref],
      opts
    )
  end

  def jido_vfs(opts \\ []) do
    resolve(
      :jido_vfs,
      ["../jido_vfs"],
      [github: "nshkrdotcom/jido_vfs", ref: @jido_vfs_ref],
      opts
    )
  end

  def sprites(opts \\ []) do
    resolve(
      :sprites,
      ["../sprites-ex", "../sprites_ex"],
      [github: "mikehostetler/sprites-ex", ref: @sprites_ref],
      opts
    )
  end

  defp resolve(app, local_paths, fallback_opts, opts) do
    case Enum.find_value(local_paths, &existing_path/1) do
      nil -> {app, Keyword.merge(fallback_opts, opts)}
      path -> {app, Keyword.merge([path: path], opts)}
    end
  end

  defp existing_path(relative_path) do
    expanded_path = Path.expand(relative_path, @project_root)

    if File.dir?(expanded_path) do
      expanded_path
    end
  end
end
