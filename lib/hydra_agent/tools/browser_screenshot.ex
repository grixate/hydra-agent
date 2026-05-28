defmodule HydraAgent.Tools.BrowserScreenshot do
  @behaviour HydraAgent.Tool

  @impl true
  def spec do
    %{
      name: "browser_screenshot",
      side_effect_class: "browser",
      timeout_ms: 10_000,
      approval_sensitive: true,
      description: "Record a browser screenshot request for artifact-backed browser workers.",
      input_schema: %{"type" => "object"},
      output_schema: %{"type" => "object"}
    }
  end

  @impl true
  def execute(input, context) do
    case HydraAgent.Browser.execute("screenshot", input, context) do
      {:ok, result} -> {:ok, Map.put(result, "artifact_required", true)}
      error -> error
    end
  end
end
