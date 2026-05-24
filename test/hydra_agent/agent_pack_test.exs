defmodule HydraAgent.AgentPackTest do
  use ExUnit.Case, async: true

  alias HydraAgent.AgentPack

  test "validates a least-privilege agent pack" do
    pack = %{
      "agent_pack_version" => 1,
      "slug" => "researcher",
      "name" => "Researcher",
      "role" => "researcher",
      "description" => "Researches grounded context.",
      "model_route" => %{"default_provider" => "fast"},
      "tools" => ["knowledge_search"],
      "skills" => [],
      "memory_scopes" => ["agent"],
      "knowledge_scopes" => ["workspace"],
      "permissions" => %{"side_effect_classes" => ["read_only"], "requires_approval" => true},
      "autonomy" => %{"level" => "recommend"},
      "approval_policy" => %{"mode" => "required_for_sensitive"}
    }

    assert {:ok, normalized} = AgentPack.validate(pack)
    assert normalized["tools"] == ["knowledge_search"]
    assert normalized["memory_scopes"] == ["agent"]
    assert normalized["knowledge_scopes"] == ["workspace"]
  end

  test "dangerous side effects must keep approval enabled" do
    pack = %{
      "agent_pack_version" => 1,
      "slug" => "builder",
      "name" => "Builder",
      "role" => "builder",
      "description" => "Builds safely.",
      "model_route" => %{"default_provider" => "strong"},
      "tools" => ["knowledge_write"],
      "skills" => [],
      "memory_scopes" => ["agent"],
      "knowledge_scopes" => ["workspace"],
      "permissions" => %{
        "side_effect_classes" => ["read_only", "shell"],
        "requires_approval" => false
      },
      "autonomy" => %{"level" => "execute_with_approval"},
      "approval_policy" => %{"mode" => "required_for_sensitive"}
    }

    assert {:error, errors} = AgentPack.validate(pack)
    assert "dangerous side effects must require approval by default" in errors
  end

  test "agent packs only reference registered tools" do
    pack = %{
      "agent_pack_version" => 1,
      "slug" => "researcher",
      "name" => "Researcher",
      "role" => "researcher",
      "description" => "Researches grounded context.",
      "model_route" => %{"default_provider" => "fast"},
      "tools" => ["made_up_tool"],
      "skills" => [],
      "memory_scopes" => ["agent"],
      "knowledge_scopes" => ["workspace"],
      "permissions" => %{"side_effect_classes" => ["read_only"], "requires_approval" => true},
      "autonomy" => %{"level" => "recommend"},
      "approval_policy" => %{"mode" => "required_for_sensitive"}
    }

    assert {:error, errors} = AgentPack.validate(pack)
    assert "tools contains unknown registered tools: made_up_tool" in errors
  end

  test "exports agent profiles back into portable packs" do
    agent = %HydraAgent.Runtime.AgentProfile{
      slug: "reviewer",
      name: "Reviewer",
      role: "reviewer",
      description: "Reviews work.",
      system_prompt: "Review carefully.",
      model_route: %{"default_provider" => "strong"},
      capability_profile: %{
        "tools" => ["knowledge_search"],
        "side_effect_classes" => ["read_only"],
        "max_autonomy_level" => "recommend",
        "approval_policy" => %{"mode" => "required_for_sensitive"}
      },
      memory_scopes: ["agent"],
      knowledge_scopes: ["workspace"]
    }

    pack = AgentPack.from_agent(agent)

    assert {:ok, normalized} = AgentPack.validate(pack)
    assert normalized["slug"] == "reviewer"
    assert normalized["tools"] == ["knowledge_search"]
  end

  test "import attrs preserve skills for export round trips" do
    pack = %{
      "agent_pack_version" => 1,
      "slug" => "reviewer",
      "name" => "Reviewer",
      "role" => "reviewer",
      "description" => "Reviews work.",
      "model_route" => %{"default_provider" => "strong"},
      "tools" => ["knowledge_search"],
      "skills" => ["code_review", "verification"],
      "memory_scopes" => ["agent"],
      "knowledge_scopes" => ["workspace"],
      "permissions" => %{"side_effect_classes" => ["read_only"], "requires_approval" => true},
      "autonomy" => %{"level" => "recommend"},
      "approval_policy" => %{"mode" => "required_for_sensitive"}
    }

    assert {:ok, attrs} = AgentPack.to_agent_attrs(pack, 1)
    assert attrs.capability_profile["skills"] == ["code_review", "verification"]

    exported =
      AgentPack.from_agent(%HydraAgent.Runtime.AgentProfile{
        slug: attrs.slug,
        name: attrs.name,
        role: attrs.role,
        description: attrs.description,
        system_prompt: attrs.system_prompt,
        model_route: attrs.model_route,
        capability_profile: attrs.capability_profile,
        memory_scopes: attrs.memory_scopes,
        knowledge_scopes: attrs.knowledge_scopes
      })

    assert exported["skills"] == ["code_review", "verification"]
  end
end
