defmodule HydraAgent.Tools.ShellCommand do
  @behaviour HydraAgent.Tool

  @impl true
  def spec do
    %{
      name: "shell_command",
      side_effect_class: "shell",
      timeout_ms: 30_000,
      approval_sensitive: true,
      description: "Run a non-interactive command allowed by the tool policy shell allowlist.",
      input_schema: %{
        "type" => "object",
        "required" => ["command"],
        "properties" => %{
          "command" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "minItems" => 1
          },
          "cwd" => %{"type" => "string"},
          "env" => %{"type" => "object"}
        }
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "array"},
          "exit_status" => %{"type" => "integer"},
          "output" => %{"type" => "string"}
        }
      }
    }
  end

  @impl true
  def execute(input, context) do
    input = stringify_keys(input || %{})
    command = input["command"]

    with {:ok, {program, args}} <- normalize_command(command),
         {:ok, cwd} <- allowed_cwd(input["cwd"], context),
         {:ok, env} <- normalize_env(input["env"] || %{}) do
      {output, exit_status} =
        System.cmd(program, args,
          cd: cwd,
          env: env,
          stderr_to_stdout: true
        )

      {:ok,
       %{
         "command" => [program | args],
         "cwd" => cwd,
         "exit_status" => exit_status,
         "output" => output
       }}
    end
  rescue
    error ->
      {:error, %{"reason" => "shell_command_failed", "error" => Exception.message(error)}}
  end

  defp normalize_command([program | args]) when is_binary(program) do
    if Enum.all?(args, &is_binary/1) do
      {:ok, {program, args}}
    else
      {:error, %{"reason" => "command_args_must_be_strings"}}
    end
  end

  defp normalize_command(_command), do: {:error, %{"reason" => "command_must_be_non_empty_list"}}

  defp allowed_cwd(nil, context), do: {:ok, context["workspace_root"] || File.cwd!()}

  defp allowed_cwd(cwd, context) when is_binary(cwd) do
    root = Path.expand(context["workspace_root"] || File.cwd!())
    expanded = Path.expand(cwd)

    if expanded == root or String.starts_with?(expanded, root <> "/") do
      {:ok, expanded}
    else
      {:error,
       %{"reason" => "cwd_outside_workspace_root", "cwd" => cwd, "workspace_root" => root}}
    end
  end

  defp allowed_cwd(_cwd, _context), do: {:error, %{"reason" => "cwd_must_be_string"}}

  defp normalize_env(env) when is_map(env) do
    entries =
      Enum.map(env, fn {key, value} ->
        {to_string(key), to_string(value)}
      end)

    {:ok, entries}
  end

  defp normalize_env(_env), do: {:error, %{"reason" => "env_must_be_object"}}

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
