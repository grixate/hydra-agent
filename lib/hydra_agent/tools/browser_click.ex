defmodule HydraAgent.Tools.BrowserClick do
  @behaviour HydraAgent.Tool

  @impl true
  def spec do
    %{
      name: "browser_click",
      side_effect_class: "browser",
      timeout_ms: 10_000,
      approval_sensitive: true,
      description: "Record a policy-gated browser click intent.",
      input_schema: %{"type" => "object", "required" => ["selector"]},
      output_schema: %{"type" => "object"}
    }
  end

  @impl true
  def execute(input, context) do
    HydraAgent.Browser.execute("click", input, context)
  end
end
