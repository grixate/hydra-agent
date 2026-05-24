defmodule HydraAgent.Skills.SkillTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Skills.Skill

  test "validates durable skill declarations" do
    changeset =
      Skill.changeset(%Skill{}, %{
        workspace_id: 1,
        name: "Grounded Research",
        slug: "grounded-research",
        description: "Collect and preserve sourced findings.",
        instructions: "Search knowledge first, then write only sourced notes.",
        required_tools: ["knowledge_search", "knowledge_write"],
        memory_scopes: ["workspace"],
        knowledge_scopes: ["workspace"]
      })

    assert changeset.valid?
  end

  test "rejects unknown tools" do
    changeset =
      Skill.changeset(%Skill{}, %{
        workspace_id: 1,
        name: "Unsafe",
        slug: "unsafe",
        description: "Uses unknown tools.",
        instructions: "Do something.",
        required_tools: ["missing_tool"]
      })

    refute changeset.valid?

    assert {"contains unknown registered tools: missing_tool", _meta} =
             changeset.errors[:required_tools]
  end
end
