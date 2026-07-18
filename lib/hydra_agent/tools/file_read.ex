defmodule HydraAgent.Tools.FileRead do
  @behaviour HydraAgent.Tool

  alias HydraAgent.Security.WorkspacePath

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
          "max_bytes" => %{"type" => "integer", "minimum" => 1, "maximum" => 1_000_000},
          "allow_binary" => %{"type" => "boolean"}
        }
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "content" => %{"type" => "string"},
          "truncated" => %{"type" => "boolean"},
          "bytes_read" => %{"type" => "integer"}
        }
      }
    }
  end

  @impl true
  def execute(input, context) do
    input = stringify_keys(input || %{})
    max_bytes = input["max_bytes"] || 500_000
    allow_binary? = input["allow_binary"] == true

    root = context["workspace_root"] || File.cwd!()

    with {:ok, path} <- WorkspacePath.resolve(root, input["path"], kind: :regular),
         :ok <- validate_max_bytes(max_bytes),
         {:ok, content} <- WorkspacePath.read_regular(root, path) do
      if binary_content?(content) and not allow_binary? do
        {:error,
         %{
           "reason" => "binary_file_not_read",
           "path" => input["path"],
           "bytes" => byte_size(content)
         }}
      else
        {content, truncated?} = truncate(content, max_bytes)

        {:ok,
         %{
           "path" => path,
           "content" => content,
           "truncated" => truncated?,
           "bytes_read" => byte_size(content)
         }}
      end
    else
      {:error, %File.Error{} = error} ->
        {:error, %{"reason" => "file_read_failed", "error" => Exception.message(error)}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp validate_max_bytes(value) when is_integer(value) and value >= 1 and value <= 1_000_000,
    do: :ok

  defp validate_max_bytes(value),
    do: {:error, %{"reason" => "invalid_max_bytes", "max_bytes" => value}}

  defp binary_content?(content) do
    not String.valid?(content) or :binary.match(content, <<0>>) != :nomatch
  end

  defp truncate(content, max_bytes) when byte_size(content) > max_bytes do
    {binary_part(content, 0, max_bytes), true}
  end

  defp truncate(content, _max_bytes), do: {content, false}

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
