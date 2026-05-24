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
          "mode" => %{"type" => "string", "enum" => ["overwrite", "append"]}
        }
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "bytes_written" => %{"type" => "integer"},
          "mode" => %{"type" => "string"}
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
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- write(path, content, mode) do
      {:ok, %{"path" => path, "bytes_written" => byte_size(content), "mode" => mode}}
    else
      {:error, %File.Error{} = error} ->
        {:error, %{"reason" => "file_write_failed", "error" => Exception.message(error)}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp write(path, content, "append"), do: File.write(path, content, [:append])
  defp write(path, content, "overwrite"), do: File.write(path, content)

  defp validate_mode(mode) when mode in ["overwrite", "append"], do: :ok

  defp validate_mode(mode),
    do: {:error, %{"reason" => "unsupported_file_write_mode", "mode" => mode}}

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

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
