defmodule HydraAgent.Tools.TextToSpeech do
  @behaviour HydraAgent.Tool

  alias HydraAgent.Tools.ArtifactRecord

  @impl true
  def spec do
    %{
      name: "text_to_speech",
      side_effect_class: "media_generation",
      timeout_ms: 30_000,
      approval_sensitive: true,
      description: "Create an artifact-backed text-to-speech request.",
      input_schema: %{"type" => "object", "required" => ["text"]},
      output_schema: %{"type" => "object"}
    }
  end

  @impl true
  def execute(input, context) do
    input = stringify_keys(input || %{})

    if present?(input["text"]) do
      ArtifactRecord.execute(
        %{
          "title" => input["title"] || "Generated speech",
          "body" => input["text"],
          "artifact_type" => "tts_request",
          "uri" => "hydra://generated/audio/#{System.unique_integer([:positive])}",
          "metadata" => %{"voice" => input["voice"], "status" => "requested"}
        },
        context
      )
    else
      {:error, %{"reason" => "tts_text_required"}}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
