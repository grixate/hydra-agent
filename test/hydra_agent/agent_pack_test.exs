defmodule HydraAgent.AgentPackTest do
  use ExUnit.Case, async: true

  alias HydraAgent.{AgentPack, Connectors}

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

  test "tool bundles expand into explicit tools and side-effect classes" do
    pack = %{
      "agent_pack_version" => 1,
      "slug" => "filesystem-reviewer",
      "name" => "Filesystem Reviewer",
      "role" => "reviewer",
      "description" => "Reviews workspace files.",
      "model_route" => %{"default_provider" => "fast"},
      "tools" => [],
      "tool_bundles" => ["files_read"],
      "skills" => [],
      "memory_scopes" => ["agent"],
      "knowledge_scopes" => ["workspace"],
      "permissions" => %{"side_effect_classes" => ["read_only"], "requires_approval" => false},
      "autonomy" => %{"level" => "recommend"},
      "approval_policy" => %{"mode" => "required_for_sensitive"}
    }

    assert {:ok, normalized} = AgentPack.validate(pack)
    assert normalized["tool_bundles"] == ["files_read"]
    assert normalized["tools"] == ["file_list", "file_read"]
    assert normalized["permissions"]["side_effect_classes"] == ["read_only"]
  end

  test "dangerous tool bundles must keep approval enabled" do
    pack = %{
      "agent_pack_version" => 1,
      "slug" => "terminal-builder",
      "name" => "Terminal Builder",
      "role" => "builder",
      "description" => "Builds with terminal tools.",
      "model_route" => %{"default_provider" => "strong"},
      "tools" => [],
      "tool_bundles" => ["terminal"],
      "skills" => [],
      "memory_scopes" => ["agent"],
      "knowledge_scopes" => ["workspace"],
      "permissions" => %{"side_effect_classes" => ["read_only"], "requires_approval" => false},
      "autonomy" => %{"level" => "execute_with_approval"},
      "approval_policy" => %{"mode" => "required_for_sensitive"}
    }

    assert {:error, errors} = AgentPack.validate(pack)
    assert "dangerous tool bundles must require approval by default" in errors
  end

  test "mcp tool bundle expands into mcp_call capability" do
    pack = %{
      "agent_pack_version" => 1,
      "slug" => "mcp-operator",
      "name" => "MCP Operator",
      "role" => "operator",
      "description" => "Uses configured MCP tools.",
      "model_route" => %{"default_provider" => "strong"},
      "tools" => [],
      "tool_bundles" => ["mcp"],
      "skills" => [],
      "memory_scopes" => ["agent"],
      "knowledge_scopes" => ["workspace"],
      "permissions" => %{"side_effect_classes" => ["read_only"], "requires_approval" => true},
      "autonomy" => %{"level" => "execute_with_approval"},
      "approval_policy" => %{"mode" => "required_for_sensitive"}
    }

    assert {:ok, normalized} = AgentPack.validate(pack)
    assert normalized["tools"] == ["mcp_call"]
    assert normalized["permissions"]["side_effect_classes"] == ["read_only", "mcp"]
  end

  test "agent packs only reference known tool bundles" do
    pack = %{
      "agent_pack_version" => 1,
      "slug" => "researcher",
      "name" => "Researcher",
      "role" => "researcher",
      "description" => "Researches grounded context.",
      "model_route" => %{"default_provider" => "fast"},
      "tools" => [],
      "tool_bundles" => ["imaginary"],
      "skills" => [],
      "memory_scopes" => ["agent"],
      "knowledge_scopes" => ["workspace"],
      "permissions" => %{"side_effect_classes" => ["read_only"], "requires_approval" => true},
      "autonomy" => %{"level" => "recommend"},
      "approval_policy" => %{"mode" => "required_for_sensitive"}
    }

    assert {:error, errors} = AgentPack.validate(pack)
    assert "tool_bundles contains unknown bundles: imaginary" in errors
  end

  test "returns structured validation details for authoring tools" do
    pack = %{
      "agent_pack_version" => 99,
      "slug" => "bad-agent",
      "name" => "Bad Agent",
      "role" => "wizard",
      "description" => "Invalid pack.",
      "model_route" => %{},
      "tools" => ["made_up_tool"],
      "tool_bundles" => ["imaginary"],
      "skills" => [],
      "memory_scopes" => ["agent"],
      "knowledge_scopes" => ["workspace"],
      "permissions" => %{"side_effect_classes" => ["telepathy"], "requires_approval" => true},
      "autonomy" => %{"level" => "too_much"},
      "approval_policy" => %{"mode" => "whenever"}
    }

    assert {:error, details} = AgentPack.validate_details(pack)

    assert %{
             "field" => "agent_pack_version",
             "code" => "unsupported_version",
             "message" => "agent_pack_version must be 1"
           } = Enum.find(details, &(&1["field"] == "agent_pack_version"))

    assert %{
             "field" => "tools",
             "code" => "unknown_registered_tools",
             "metadata" => %{"unknown" => ["made_up_tool"]}
           } = Enum.find(details, &(&1["field"] == "tools"))

    assert "tools contains unknown registered tools: made_up_tool" in AgentPack.error_messages(
             details
           )
  end

  test "generates a JSON schema with current runtime enums" do
    schema = AgentPack.json_schema()

    assert schema["$id"] =~ "agent-pack-v1"
    assert "agent_pack_version" in schema["required"]
    assert schema["properties"]["agent_pack_version"]["const"] == AgentPack.version()
    assert "researcher" in schema["properties"]["role"]["enum"]
    assert "knowledge_search" in schema["properties"]["tools"]["items"]["enum"]
    assert "files_read" in schema["properties"]["tool_bundles"]["items"]["enum"]
    assert schema["properties"]["connector_requirements"]["items"]["type"] == "string"
    assert schema["properties"]["automation_recipes"]["items"]["type"] == "string"
    assert schema["properties"]["room_defaults"]["type"] == "object"

    assert "execute_with_approval" in schema["properties"]["autonomy"]["properties"]["level"][
             "enum"
           ]
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

  test "import attrs preserve pack metadata for starter pack round trips" do
    pack = %{
      "agent_pack_version" => 1,
      "slug" => "daily-chief-of-staff",
      "name" => "Daily Chief of Staff",
      "role" => "operator",
      "description" => "Coordinates daily work.",
      "model_route" => %{"default_provider" => "strong"},
      "tools" => [],
      "tool_bundles" => ["knowledge_write"],
      "skills" => ["daily_briefing"],
      "memory_scopes" => ["agent", "workspace"],
      "knowledge_scopes" => ["workspace"],
      "connector_requirements" => ["telegram", "email", "calendar"],
      "automation_recipes" => ["daily_briefing", "meeting_prep"],
      "room_defaults" => %{"mention_handle" => "chief", "response_mode" => "coordinator"},
      "task_pack" => "daily_os",
      "delivery_targets" => ["telegram", "email"],
      "permissions" => %{"side_effect_classes" => ["read_only"], "requires_approval" => true},
      "autonomy" => %{"level" => "execute_with_approval"},
      "approval_policy" => %{"mode" => "required_for_sensitive"}
    }

    assert {:ok, attrs} = AgentPack.to_agent_attrs(pack, 1)
    assert attrs.capability_profile["connector_requirements"] == ["telegram", "email", "calendar"]
    assert attrs.capability_profile["automation_recipes"] == ["daily_briefing", "meeting_prep"]
    assert attrs.capability_profile["room_defaults"]["mention_handle"] == "chief"
    assert attrs.capability_profile["task_pack"] == "daily_os"

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

    assert exported["connector_requirements"] == ["telegram", "email", "calendar"]
    assert exported["automation_recipes"] == ["daily_briefing", "meeting_prep"]
    assert exported["room_defaults"]["response_mode"] == "coordinator"
    assert exported["task_pack"] == "daily_os"
    assert exported["delivery_targets"] == ["telegram", "email"]
  end

  test "bundled starter packs validate" do
    packs = AgentPack.builtin_packs()
    slugs = Enum.map(packs, &get_in(&1, ["pack", "slug"]))

    assert "daily-chief-of-staff" in slugs
    assert "research-watch" in slugs
    assert "content-drafter" in slugs
    assert Enum.all?(packs, &(&1["status"] == "valid"))
  end

  test "bundled starter packs only request seeded connectors" do
    seeded_connectors = Connectors.provider_specs() |> Enum.map(& &1.provider) |> MapSet.new()

    requested_connectors =
      AgentPack.valid_builtin_packs()
      |> Enum.flat_map(&(&1["connector_requirements"] || []))
      |> MapSet.new()

    assert MapSet.subset?(requested_connectors, seeded_connectors)
  end
end
