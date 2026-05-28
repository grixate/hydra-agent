defmodule HydraAgent.Tools.BrowserExtract do
  @behaviour HydraAgent.Tool

  @impl true
  def spec do
    %{
      name: "browser_extract",
      side_effect_class: "browser",
      timeout_ms: 10_000,
      approval_sensitive: true,
      description: "Record a browser extraction request.",
      input_schema: %{"type" => "object"},
      output_schema: %{"type" => "object"}
    }
  end

  @impl true
  def execute(input, context) do
    HydraAgent.Browser.execute("extract", input, context)
  end
end
