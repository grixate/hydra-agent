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
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "sleep_ms" => %{"type" => "integer", "minimum" => 0, "maximum" => 1_000},
          "timeout_ms" => %{"type" => "integer", "minimum" => 1, "maximum" => 1_000}
        }
      },
      output_schema: %{"type" => "object", "properties" => %{"input" => %{"type" => "object"}}}
    }
  end

  @impl true
  def execute(input, _context) do
    input = input || %{}
    sleep_ms = input["sleep_ms"] || input[:sleep_ms] || 0

    if is_integer(sleep_ms) and sleep_ms > 0 do
      Process.sleep(min(sleep_ms, 1_000))
    end

    {:ok, %{"input" => input}}
  end
end
