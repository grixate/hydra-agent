defmodule HydraAgent.Runtime.PlannerTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Runtime.Planner

  test "parses strict JSON plans" do
    content = ~s|{
      "steps": [
        {
          "title": "Search memory",
          "tool_name": "knowledge_search",
          "side_effect_class": "read_only",
          "input": {"query": "runtime"}
        }
      ]
    }|

    assert {:ok, [step]} = Planner.parse_plan(content)
    assert step["title"] == "Search memory"
    assert step["tool_name"] == "knowledge_search"
    assert step["input"]["query"] == "runtime"
  end

  test "parses fenced JSON plans" do
    content = """
    ```json
    {"steps":[{"title":"Noop","tool_name":"noop","input":{}}]}
    ```
    """

    assert {:ok, [step]} = Planner.parse_plan(content)
    assert step["side_effect_class"] == "read_only"
  end

  test "rejects invalid JSON" do
    assert {:error, %{"reason" => "invalid_plan_json"}} = Planner.parse_plan("not json")
  end
end
