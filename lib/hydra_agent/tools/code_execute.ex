defmodule HydraAgent.Tools.CodeExecute do
  @behaviour HydraAgent.Tool

  alias HydraAgent.Security.{TrustedProgram, WorkspacePath}

  @allowed_runtimes ~w(elixir node)

  @safe_elixir_local_calls ~w(+ - * / div rem == != === !== < > <= >= and or not ! <> in
    length byte_size map_size tuple_size elem hd tl abs min max round trunc floor ceil)a

  @safe_elixir_remote_calls MapSet.new([
                              {IO, :write},
                              {IO, :puts},
                              {IO, :inspect},
                              {String, :length},
                              {String, :upcase},
                              {String, :downcase},
                              {String, :trim},
                              {String, :split},
                              {String, :join},
                              {String, :replace},
                              {String, :contains?},
                              {Integer, :to_string},
                              {Integer, :parse},
                              {Float, :parse},
                              {Float, :round},
                              {Map, :get},
                              {Map, :put},
                              {Map, :keys},
                              {Map, :values},
                              {List, :flatten},
                              {Kernel, :inspect},
                              {Kernel, :to_string}
                            ])

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

    context = stringify_keys(context || %{})
    root = context["workspace_root"] || File.cwd!()
    max_output_bytes = input["max_output_bytes"] || 100_000

    with true <- runtime in @allowed_runtimes,
         true <- is_binary(code) and byte_size(code) <= 20_000,
         :ok <- validate_safe_code(runtime, code),
         :ok <- validate_max_output_bytes(max_output_bytes),
         {:ok, cwd} <- allowed_cwd(input["cwd"], context),
         {:ok, program} <- TrustedProgram.resolve(runtime, root, allowed: @allowed_runtimes) do
      args = runtime_args(runtime, code)
      {output, exit_status} = System.cmd(program, args, cd: cwd, stderr_to_stdout: true)
      {output, truncated?} = truncate(output, max_output_bytes)

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
    case Enum.find(unsafe_patterns(runtime), &String.contains?(code, &1)) do
      nil -> validate_runtime_code(runtime, code)
      pattern -> {:error, %{"reason" => "unsafe_code_execution", "pattern" => pattern}}
    end
  end

  defp unsafe_patterns(runtime), do: Map.get(@unsafe_patterns, runtime, [])

  defp validate_runtime_code("node", _code), do: :ok

  defp validate_runtime_code("elixir", code) do
    with {:ok, ast} <- Code.string_to_quoted(code),
         true <- safe_elixir_ast?(ast) do
      :ok
    else
      _invalid -> {:error, %{"reason" => "unsafe_code_execution", "pattern" => "elixir_ast"}}
    end
  end

  defp runtime_args("node", code), do: ["--permission", "-e", code]
  defp runtime_args("elixir", code), do: ["-e", code]

  defp allowed_cwd(nil, context),
    do: WorkspacePath.resolve(context["workspace_root"] || File.cwd!(), ".", kind: :directory)

  defp allowed_cwd(cwd, context) when is_binary(cwd) do
    root = Path.expand(context["workspace_root"] || File.cwd!())

    case WorkspacePath.resolve(root, cwd, kind: :directory) do
      {:error, %{"reason" => "path_outside_workspace_root"}} ->
        {:error, %{"reason" => "code_cwd_outside_workspace_root"}}

      result ->
        result
    end
  end

  defp safe_elixir_ast?(value)
       when is_number(value) or is_binary(value) or is_atom(value),
       do: true

  defp safe_elixir_ast?(list) when is_list(list), do: Enum.all?(list, &safe_elixir_ast?/1)

  defp safe_elixir_ast?({{:., _meta, [{:__aliases__, _, parts}, function]}, _call_meta, args})
       when is_atom(function) and is_list(args) do
    module = Module.concat(parts)

    MapSet.member?(@safe_elixir_remote_calls, {module, function}) and
      Enum.all?(args, &safe_elixir_ast?/1)
  end

  defp safe_elixir_ast?({:%{}, _meta, pairs}),
    do: Enum.all?(pairs, fn {key, value} -> safe_elixir_ast?(key) and safe_elixir_ast?(value) end)

  defp safe_elixir_ast?({:{}, _meta, values}), do: Enum.all?(values, &safe_elixir_ast?/1)
  defp safe_elixir_ast?({:__block__, _meta, values}), do: Enum.all?(values, &safe_elixir_ast?/1)

  defp safe_elixir_ast?({:=, _meta, [{name, _, context}, value]})
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: safe_elixir_ast?(value)

  defp safe_elixir_ast?({name, _meta, context})
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: true

  defp safe_elixir_ast?({call, _meta, args})
       when call in @safe_elixir_local_calls and is_list(args),
       do: Enum.all?(args, &safe_elixir_ast?/1)

  defp safe_elixir_ast?(_ast), do: false

  defp validate_max_output_bytes(value)
       when is_integer(value) and value >= 1 and value <= 1_000_000,
       do: :ok

  defp validate_max_output_bytes(value),
    do: {:error, %{"reason" => "invalid_max_output_bytes", "max_output_bytes" => value}}

  defp truncate(output, max_bytes) when byte_size(output) > max_bytes,
    do: {binary_part(output, 0, max_bytes), true}

  defp truncate(output, _max_bytes), do: {output, false}
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
