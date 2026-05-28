defmodule HydraAgent.Tools.VisionAnalyze do
  @behaviour HydraAgent.Tool

  @image_extensions ~w(.png .jpg .jpeg .gif .webp)

  @impl true
  def spec do
    %{
      name: "vision_analyze",
      side_effect_class: "read_only",
      timeout_ms: 15_000,
      approval_sensitive: false,
      description: "Validate and describe an image input for vision-capable provider workflows.",
      input_schema: %{"type" => "object"},
      output_schema: %{"type" => "object"}
    }
  end

  @impl true
  def execute(input, _context) do
    input = stringify_keys(input || %{})
    source = input["path"] || input["url"] || input["artifact_id"]

    cond do
      is_binary(input["path"]) and image_path?(input["path"]) ->
        {:ok,
         %{
           "source" => source,
           "modality" => "image",
           "analysis" => "image accepted for vision analysis"
         }}

      is_binary(input["url"]) and image_path?(URI.parse(input["url"]).path || "") ->
        {:ok,
         %{
           "source" => source,
           "modality" => "image",
           "analysis" => "image URL accepted for vision analysis"
         }}

      is_integer(input["artifact_id"]) ->
        {:ok,
         %{
           "source" => source,
           "modality" => "image",
           "analysis" => "artifact accepted for vision analysis"
         }}

      true ->
        {:error, %{"reason" => "unsupported_vision_input"}}
    end
  end

  defp image_path?(path), do: (path |> Path.extname() |> String.downcase()) in @image_extensions
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
