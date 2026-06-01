defmodule HydraAgent.Tools.ProjectSkillRun do
  @behaviour HydraAgent.Tool

  @runtimes %{
    "shell" => "bash",
    "node" => "node",
    "elixir" => "elixir"
  }

  @impl true
  def spec do
    %{
      name: "project_skill_run",
      side_effect_class: "code_execution",
      timeout_ms: 30_000,
      approval_sensitive: true,
      description: "Execute an entrypoint from a project-local Hydra code skill directory.",
      input_schema: %{
        "type" => "object",
        "required" => ["skill_slug", "entrypoint", "runtime"]
      },
      output_schema: %{"type" => "object"}
    }
  end

  @impl true
  def execute(input, context) do
    input = stringify_keys(input || %{})
    context = stringify_keys(context || %{})

    with {:ok, runtime} <- runtime(input["runtime"]),
         {:ok, root} <- workspace_root(context),
         {:ok, slug} <- safe_segment(input["skill_slug"], "skill_slug"),
         {:ok, entrypoint} <- safe_entrypoint(input["entrypoint"]),
         skill_dir <- Path.join([root, ".hydra", "skills", slug]),
         executable <- Path.expand(Path.join(skill_dir, entrypoint)),
         :ok <- inside?(executable, skill_dir),
         true <- File.regular?(executable) do
      args = safe_args(input["args"] || [])

      {output, exit_status} =
        System.cmd(runtime, [executable | args], cd: skill_dir, stderr_to_stdout: true)

      {output, truncated?} = truncate(output, input["max_output_bytes"] || 100_000)

      {:ok,
       %{
         "skill_slug" => slug,
         "entrypoint" => entrypoint,
         "runtime" => input["runtime"],
         "exit_status" => exit_status,
         "output" => output,
         "truncated" => truncated?
       }}
    else
      false -> {:error, %{"reason" => "project_skill_entrypoint_missing"}}
      error -> error
    end
  rescue
    error ->
      {:error,
       %{"reason" => "project_skill_execution_failed", "error" => Exception.message(error)}}
  end

  defp runtime(value) when is_binary(value) do
    case Map.fetch(@runtimes, value) do
      {:ok, runtime} -> {:ok, runtime}
      :error -> {:error, %{"reason" => "unsupported_project_skill_runtime"}}
    end
  end

  defp runtime(_value), do: {:error, %{"reason" => "unsupported_project_skill_runtime"}}

  defp workspace_root(context) do
    root = context["workspace_root"] || File.cwd!()
    {:ok, Path.expand(root)}
  end

  defp safe_segment(value, field) when is_binary(value) do
    if Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, value) do
      {:ok, value}
    else
      {:error, %{"reason" => "unsafe_project_skill_#{field}"}}
    end
  end

  defp safe_segment(_value, field), do: {:error, %{"reason" => "unsafe_project_skill_#{field}"}}

  defp safe_entrypoint(value) when is_binary(value) do
    normalized = String.replace(value, "\\", "/")

    cond do
      Path.type(normalized) == :absolute ->
        {:error, %{"reason" => "unsafe_project_skill_entrypoint"}}

      String.contains?(normalized, "..") ->
        {:error, %{"reason" => "unsafe_project_skill_entrypoint"}}

      normalized == "" ->
        {:error, %{"reason" => "unsafe_project_skill_entrypoint"}}

      true ->
        {:ok, normalized}
    end
  end

  defp safe_entrypoint(_value), do: {:error, %{"reason" => "unsafe_project_skill_entrypoint"}}

  defp safe_args(args) when is_list(args), do: Enum.map(args, &to_string/1) |> Enum.take(20)
  defp safe_args(_args), do: []

  defp inside?(path, root) do
    expanded_root = Path.expand(root)

    if path == expanded_root or String.starts_with?(path, expanded_root <> "/") do
      :ok
    else
      {:error, %{"reason" => "project_skill_entrypoint_outside_workspace"}}
    end
  end

  defp truncate(output, max_bytes) when byte_size(output) > max_bytes,
    do: {binary_part(output, 0, max_bytes), true}

  defp truncate(output, _max_bytes), do: {output, false}
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
