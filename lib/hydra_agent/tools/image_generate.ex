defmodule HydraAgent.Tools.ImageGenerate do
  @behaviour HydraAgent.Tool

  alias HydraAgent.Tools.ArtifactRecord

  @impl true
  def spec do
    %{
      name: "image_generate",
      side_effect_class: "media_generation",
      timeout_ms: 30_000,
      approval_sensitive: true,
      description: "Create an artifact-backed image generation request.",
      input_schema: %{"type" => "object", "required" => ["prompt"]},
      output_schema: %{"type" => "object"}
    }
  end

  @impl true
  def execute(input, context) do
    input = stringify_keys(input || %{})

    if present?(input["prompt"]) do
      ArtifactRecord.execute(
        %{
          "title" => input["title"] || "Generated image",
          "body" => input["prompt"],
          "artifact_type" => "image_generation_request",
          "uri" => "hydra://generated/image/#{System.unique_integer([:positive])}",
          "metadata" => %{"model" => input["model"], "status" => "requested"}
        },
        context
      )
    else
      {:error, %{"reason" => "image_prompt_required"}}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
