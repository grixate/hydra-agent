defmodule HydraAgent.Tools.FileList do
  @behaviour HydraAgent.Tool

  @impl true
  def spec do
    %{
      name: "file_list",
      side_effect_class: "read_only",
      timeout_ms: 10_000,
      approval_sensitive: false,
      description:
        "List files below a workspace path allowed by the tool policy filesystem allowlist.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "recursive" => %{"type" => "boolean"},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 1000}
        }
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "entries" => %{"type" => "array"}
        }
      }
    }
  end

  @impl true
  def execute(input, context) do
    input = stringify_keys(input || %{})
    limit = input["limit"] || 200

    with {:ok, path} <- resolve_workspace_path(input["path"] || ".", context),
         true <-
           File.dir?(path) ||
             {:error, %{"reason" => "not_directory", "path" => input["path"] || "."}},
         {:ok, entries} <- list_entries(path, input["recursive"] == true, limit) do
      {:ok, %{"path" => path, "entries" => entries}}
    else
      {:error, %File.Error{} = error} ->
        {:error, %{"reason" => "file_list_failed", "error" => Exception.message(error)}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp list_entries(path, false, limit) do
    entries =
      path
      |> File.ls!()
      |> Enum.take(limit)
      |> Enum.map(&entry(Path.join(path, &1)))

    {:ok, entries}
  rescue
    error in File.Error -> {:error, error}
  end

  defp list_entries(path, true, limit) do
    entries =
      path
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.take(limit)
      |> Enum.map(&entry/1)

    {:ok, entries}
  end

  defp entry(path) do
    %{
      "path" => path,
      "type" => if(File.dir?(path), do: "directory", else: "file"),
      "size" => if(File.regular?(path), do: File.stat!(path).size, else: nil)
    }
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

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
