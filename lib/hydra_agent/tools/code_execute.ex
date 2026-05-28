defmodule HydraAgent.Tools.CodeExecute do
  @behaviour HydraAgent.Tool

  @allowed_runtimes %{
    "elixir" => ["elixir", "-e"],
    "node" => ["node", "-e"]
  }

  @unsafe_patterns %{
    "elixir" => ~w(
      Req.
      HTTPoison
      Finch.
      Mint.
      :httpc
      :hackney
      File.
      Path.wildcard
      System.
      Port.
      open_port
      :os.cmd
      Code.eval_file
      Code.require_file
    ),
    "node" => ~w(
      require(
      import(
      child_process
      fs.
      node:fs
      http.
      https.
      net.
      dgram.
      fetch(
      process.env
      Bun.
      Deno.
    )
  }

  @impl true
  def spec do
    %{
      name: "code_execute",
      side_effect_class: "code_execution",
      timeout_ms: 15_000,
      approval_sensitive: true,
      description:
        "Execute a small code snippet in an allowed local runtime without network access.",
      input_schema: %{"type" => "object", "required" => ["runtime", "code"]},
      output_schema: %{"type" => "object"}
    }
  end

  @impl true
  def execute(input, context) do
    input = stringify_keys(input || %{})
    runtime = input["runtime"]
    code = input["code"]

    with true <- Map.has_key?(@allowed_runtimes, runtime),
         true <- is_binary(code) and byte_size(code) <= 20_000,
         :ok <- validate_safe_code(runtime, code),
         {:ok, cwd} <- allowed_cwd(input["cwd"], stringify_keys(context || %{})) do
      [program, flag] = @allowed_runtimes[runtime]
      {output, exit_status} = System.cmd(program, [flag, code], cd: cwd, stderr_to_stdout: true)
      {output, truncated?} = truncate(output, input["max_output_bytes"] || 100_000)

      {:ok,
       %{
         "runtime" => runtime,
         "exit_status" => exit_status,
         "output" => output,
         "truncated" => truncated?
       }}
    else
      false -> {:error, %{"reason" => "unsupported_or_oversized_code_execution"}}
      error -> error
    end
  rescue
    error -> {:error, %{"reason" => "code_execution_failed", "error" => Exception.message(error)}}
  end

  defp validate_safe_code(runtime, code) do
    runtime
    |> unsafe_patterns()
    |> Enum.find(&String.contains?(code, &1))
    |> case do
      nil -> :ok
      pattern -> {:error, %{"reason" => "unsafe_code_execution", "pattern" => pattern}}
    end
  end

  defp unsafe_patterns(runtime), do: Map.get(@unsafe_patterns, runtime, [])

  defp allowed_cwd(nil, context), do: {:ok, context["workspace_root"] || File.cwd!()}

  defp allowed_cwd(cwd, context) when is_binary(cwd) do
    root = Path.expand(context["workspace_root"] || File.cwd!())
    expanded = Path.expand(cwd)

    if expanded == root or String.starts_with?(expanded, root <> "/") do
      {:ok, expanded}
    else
      {:error, %{"reason" => "code_cwd_outside_workspace_root"}}
    end
  end

  defp truncate(output, max_bytes) when byte_size(output) > max_bytes,
    do: {binary_part(output, 0, max_bytes), true}

  defp truncate(output, _max_bytes), do: {output, false}
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
