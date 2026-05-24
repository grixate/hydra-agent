defmodule HydraAgent.Tools.FileRead do
  @behaviour HydraAgent.Tool

  @impl true
  def spec do
    %{
      name: "file_read",
      side_effect_class: "read_only",
      timeout_ms: 10_000,
      approval_sensitive: false,
      description: "Read a workspace file allowed by the tool policy filesystem allowlist.",
      input_schema: %{
        "type" => "object",
        "required" => ["path"],
        "properties" => %{
          "path" => %{"type" => "string"},
          "max_bytes" => %{"type" => "integer", "minimum" => 1, "maximum" => 1_000_000}
        }
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "content" => %{"type" => "string"},
          "truncated" => %{"type" => "boolean"}
        }
      }
    }
  end

  @impl true
  def execute(input, context) do
    input = stringify_keys(input || %{})
    max_bytes = input["max_bytes"] || 500_000

    with {:ok, path} <- resolve_workspace_path(input["path"], context),
         true <-
           File.regular?(path) ||
             {:error, %{"reason" => "not_regular_file", "path" => input["path"]}},
         {:ok, content} <- File.read(path) do
      {content, truncated?} = truncate(content, max_bytes)
      {:ok, %{"path" => path, "content" => content, "truncated" => truncated?}}
    else
      {:error, %File.Error{} = error} ->
        {:error, %{"reason" => "file_read_failed", "error" => Exception.message(error)}}

      {:error, error} ->
        {:error, error}
    end
  end

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

  defp truncate(content, max_bytes) when byte_size(content) > max_bytes do
    {binary_part(content, 0, max_bytes), true}
  end

  defp truncate(content, _max_bytes), do: {content, false}

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
