defmodule HydraAgent.Tools.BrowserNavigate do
  @behaviour HydraAgent.Tool

  @impl true
  def spec do
    %{
      name: "browser_navigate",
      side_effect_class: "browser",
      timeout_ms: 10_000,
      approval_sensitive: true,
      description: "Record a policy-gated browser navigation target for browser-capable workers.",
      input_schema: %{"type" => "object", "required" => ["url"]},
      output_schema: %{"type" => "object"}
    }
  end

  @impl true
  def execute(input, context) do
    HydraAgent.Browser.execute("navigate", input, context)
  end
end
