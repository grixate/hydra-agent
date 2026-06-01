defmodule HydraAgent.Tools.BrowserType do
  @behaviour HydraAgent.Tool

  @impl true
  def spec do
    %{
      name: "browser_type",
      side_effect_class: "browser",
      timeout_ms: 10_000,
      approval_sensitive: true,
      description: "Record a policy-gated browser typing intent.",
      input_schema: %{"type" => "object", "required" => ["selector", "text"]},
      output_schema: %{"type" => "object"}
    }
  end

  @impl true
  def execute(input, context) do
    case HydraAgent.Browser.execute("type", input, context) do
      {:ok, result} ->
        text = stringify_keys(input || %{})["text"] || ""
        {:ok, Map.put(result, "text_bytes", byte_size(text))}

      error ->
        error
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
