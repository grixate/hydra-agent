defmodule HydraAgent.Tools.Noop do
  @behaviour HydraAgent.Tool

  @impl true
  def spec do
    %{
      name: "noop",
      side_effect_class: "read_only",
      timeout_ms: 1_000,
      approval_sensitive: false,
      description: "Return the input payload without side effects.",
      input_schema: %{"type" => "object"},
      output_schema: %{"type" => "object", "properties" => %{"input" => %{"type" => "object"}}}
    }
  end

  @impl true
  def execute(input, _context), do: {:ok, %{"input" => input || %{}}}
end
