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
          "env" => %{"type" => "object"},
          "checkpoint_paths" => %{
            "type" => "array",
            "items" => %{"type" => "string"}
          },
          "max_output_bytes" => %{"type" => "integer", "minimum" => 1, "maximum" => 1_000_000}
        }
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "array"},
          "checkpoints" => %{"type" => "array"},
          "exit_status" => %{"type" => "integer"},
          "output" => %{"type" => "string"},
          "output_bytes" => %{"type" => "integer"},
          "truncated" => %{"type" => "boolean"}
        }
      }
    }
  end

  @impl true
  def execute(input, context) do
    input = stringify_keys(input || %{})
    context = stringify_keys(context || %{})
    command = input["command"]
    max_output_bytes = input["max_output_bytes"] || 200_000

    with {:ok, {program, args}} <- normalize_command(command),
         {:ok, cwd} <- allowed_cwd(input["cwd"], context),
         {:ok, env} <- normalize_env(input["env"] || %{}, context["shell_env_allowlist"] || []),
         {:ok, checkpoints} <- checkpoint_paths(input["checkpoint_paths"], command, context),
         :ok <- validate_max_output_bytes(max_output_bytes) do
      {output, exit_status} =
        System.cmd(program, args,
          cd: cwd,
          env: env,
          stderr_to_stdout: true
        )

      {output, truncated?} = truncate(output, max_output_bytes)

      {:ok,
       %{
         "command" => [program | args],
         "cwd" => cwd,
         "checkpoints" => checkpoints,
         "exit_status" => exit_status,
         "output" => output,
         "output_bytes" => byte_size(output),
         "truncated" => truncated?
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

  defp checkpoint_paths(nil, command, context) do
    {:ok, HydraAgent.Tools.Checkpoints.path_checkpoints(infer_checkpoint_paths(command), context)}
  end

  defp checkpoint_paths(paths, _command, context) when is_list(paths) do
    if Enum.all?(paths, &is_binary/1) do
      checkpoints = HydraAgent.Tools.Checkpoints.path_checkpoints(paths, context)
      {:ok, checkpoints}
    else
      {:error, %{"reason" => "checkpoint_paths_must_be_strings"}}
    end
  end

  defp checkpoint_paths(_paths, _command, _context),
    do: {:error, %{"reason" => "checkpoint_paths_must_be_array"}}

  defp infer_checkpoint_paths(["rm" | paths]),
    do: Enum.reject(paths, &String.starts_with?(&1, "-"))

  defp infer_checkpoint_paths(["mv", from, to | _rest]), do: [from, to]
  defp infer_checkpoint_paths(["cp", _from, to | _rest]), do: [to]

  defp infer_checkpoint_paths(["truncate" | args]),
    do: Enum.reject(args, &String.starts_with?(&1, "-"))

  defp infer_checkpoint_paths(["sh", "-c", script | _rest]), do: infer_redirection_targets(script)

  defp infer_checkpoint_paths(["bash", "-c", script | _rest]),
    do: infer_redirection_targets(script)

  defp infer_checkpoint_paths(_command), do: []

  defp infer_redirection_targets(script) when is_binary(script) do
    ~r/(?:^|\s)(?:>|>>)\s*([^\s;&|]+)/
    |> Regex.scan(script)
    |> Enum.map(fn [_match, path] -> String.trim(path, ~s('"')) end)
  end

  defp normalize_env(env, allowlist) when is_map(env) and is_list(allowlist) do
    entries = Enum.map(env, fn {key, value} -> {to_string(key), to_string(value)} end)

    with :ok <- validate_env_names(entries),
         :ok <- validate_env_allowlist(entries, allowlist) do
      {:ok, entries}
    end
  end

  defp normalize_env(_env, _allowlist), do: {:error, %{"reason" => "env_must_be_object"}}

  defp validate_env_names(entries) do
    invalid =
      entries
      |> Enum.map(fn {key, _value} -> key end)
      |> Enum.reject(&Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, &1))

    if invalid == [] do
      :ok
    else
      {:error, %{"reason" => "invalid_env_names", "env" => invalid}}
    end
  end

  defp validate_env_allowlist([], _allowlist), do: :ok
  defp validate_env_allowlist(_entries, ["*" | _allowlist]), do: :ok

  defp validate_env_allowlist(entries, allowlist) do
    keys = Enum.map(entries, fn {key, _value} -> key end)
    disallowed = keys -- allowlist

    if disallowed == [] do
      :ok
    else
      {:error, %{"reason" => "shell_env_not_allowed", "env" => disallowed}}
    end
  end

  defp validate_max_output_bytes(value)
       when is_integer(value) and value >= 1 and value <= 1_000_000,
       do: :ok

  defp validate_max_output_bytes(value),
    do: {:error, %{"reason" => "invalid_max_output_bytes", "max_output_bytes" => value}}

  defp truncate(output, max_bytes) when byte_size(output) > max_bytes do
    {binary_part(output, 0, max_bytes), true}
  end

  defp truncate(output, _max_bytes), do: {output, false}

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
