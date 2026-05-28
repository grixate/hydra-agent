defmodule HydraAgent.Tools.FileWrite do
  @behaviour HydraAgent.Tool

  @impl true
  def spec do
    %{
      name: "file_write",
      side_effect_class: "workspace_write",
      timeout_ms: 10_000,
      approval_sensitive: true,
      description: "Write a workspace file allowed by the tool policy filesystem allowlist.",
      input_schema: %{
        "type" => "object",
        "required" => ["path", "content"],
        "properties" => %{
          "path" => %{"type" => "string"},
          "content" => %{"type" => "string"},
          "mode" => %{"type" => "string", "enum" => ["overwrite", "append", "create_new"]},
          "checkpoint" => %{"type" => "boolean"},
          "expected_sha256" => %{"type" => "string"}
        }
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "bytes_written" => %{"type" => "integer"},
          "mode" => %{"type" => "string"},
          "sha256" => %{"type" => "string"},
          "existed" => %{"type" => "boolean"},
          "checkpoint" => %{"type" => "object"}
        }
      }
    }
  end

  @impl true
  def execute(input, context) do
    input = stringify_keys(input || %{})
    mode = input["mode"] || "overwrite"
    content = input["content"] || ""

    with {:ok, path} <- resolve_workspace_path(input["path"], context),
         :ok <- validate_mode(mode),
         :ok <- validate_expected_sha(path, input["expected_sha256"]),
         :ok <- File.mkdir_p(Path.dirname(path)),
         existed_before <- File.exists?(path),
         checkpoint <- checkpoint_file(path, context, input),
         :ok <- write(path, content, mode) do
      {:ok,
       %{
         "path" => path,
         "bytes_written" => byte_size(content),
         "mode" => mode,
         "sha256" => sha256_file(path),
         "existed" => existed_before,
         "checkpoint" => checkpoint
       }}
    else
      {:error, %File.Error{} = error} ->
        {:error, %{"reason" => "file_write_failed", "error" => Exception.message(error)}}

      {:error, reason} when is_atom(reason) ->
        {:error, %{"reason" => "file_write_failed", "error" => to_string(reason)}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp write(path, content, "append"), do: File.write(path, content, [:append])
  defp write(path, content, "overwrite"), do: File.write(path, content)
  defp write(path, content, "create_new"), do: File.write(path, content, [:exclusive])

  defp checkpoint_file(_path, _context, %{"mode" => "create_new"}), do: %{"enabled" => false}

  defp checkpoint_file(path, context, input) do
    enabled? = Map.get(input, "checkpoint", true)

    HydraAgent.Tools.Checkpoints.file_checkpoint(path, stringify_keys(context || %{}),
      enabled: enabled?,
      tool_name: "file_write",
      reason: "file_write"
    )
  end

  defp validate_mode(mode) when mode in ["overwrite", "append", "create_new"], do: :ok

  defp validate_mode(mode),
    do: {:error, %{"reason" => "unsupported_file_write_mode", "mode" => mode}}

  defp validate_expected_sha(_path, nil), do: :ok

  defp validate_expected_sha(path, expected_sha) when is_binary(expected_sha) do
    cond do
      not File.exists?(path) ->
        {:error, %{"reason" => "expected_sha256_file_missing", "path" => path}}

      sha256_file(path) == expected_sha ->
        :ok

      true ->
        {:error,
         %{
           "reason" => "expected_sha256_mismatch",
           "path" => path,
           "expected_sha256" => expected_sha,
           "actual_sha256" => sha256_file(path)
         }}
    end
  end

  defp validate_expected_sha(_path, expected_sha),
    do:
      {:error, %{"reason" => "expected_sha256_must_be_string", "expected_sha256" => expected_sha}}

  defp resolve_workspace_path(path, context) when is_binary(path) do
    root = Path.expand(context["workspace_root"] || File.cwd!())
    expanded = Path.expand(path, root)

    if expanded == root or String.starts_with?(expanded, root <> "/") do
      {:ok, expanded}
    else
      {:error,
       %{"reason" => "path_outside_workspace_root", "path" => path, "workspace_root" => root}}
    end
  end

  defp resolve_workspace_path(_path, _context), do: {:error, %{"reason" => "path_required"}}

  defp sha256_file(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
