defmodule HydraAgent.Runtime.AgentMatcherTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Runtime.{AgentMatcher, AgentProfile}

  test "selects active agents by tool and side-effect capability" do
    researcher = %AgentProfile{
      id: 1,
      name: "Researcher",
      status: "active",
      role: "researcher",
      capability_profile: %{
        "tools" => ["http_fetch"],
        "side_effect_classes" => ["read_only", "network"]
      }
    }

    reviewer = %AgentProfile{
      id: 2,
      name: "Reviewer",
      status: "active",
      role: "reviewer",
      capability_profile: %{
        "tools" => ["knowledge_search"],
        "side_effect_classes" => ["read_only"]
      }
    }

    step = %{"tool_name" => "http_fetch", "side_effect_class" => "network"}

    assert AgentMatcher.best_agent([reviewer, researcher], step).id == researcher.id
  end

  test "does not override explicit assignment" do
    step = %{"assigned_agent_id" => 42, "tool_name" => "http_fetch"}

    assert AgentMatcher.assign_step(step, []) == step
  end

  test "assigns unclaimed steps when a matching agent exists" do
    agent = %AgentProfile{
      id: 7,
      name: "Builder",
      status: "active",
      role: "builder",
      capability_profile: %{
        "tools" => ["file_read"],
        "side_effect_classes" => ["read_only"]
      }
    }

    assert AgentMatcher.assign_step(%{"tool_name" => "file_read"}, [agent])["assigned_agent_id"] ==
             7
  end
end
