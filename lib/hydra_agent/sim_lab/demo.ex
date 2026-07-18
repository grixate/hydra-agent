defmodule HydraAgent.SimLab.Demo do
  @moduledoc false

  def study do
    %{
      id: "certificate-visibility",
      title: "Certificate visibility",
      question:
        "How will employees react if completed learning certificates become visible in their HR profile?",
      domain: "Corporate learning / HR platform",
      region: "Russia · large enterprise",
      confidence: 62,
      source_mix: %{user_data: 2, web_research: 8, assumptions: 3},
      personas: personas(),
      patterns: patterns(),
      events: events()
    }
  end

  def simulation_input do
    %{personas: personas(), patterns: patterns(), events: events(), seed: 713, agent_count: 5_000}
  end

  defp personas do
    [
      %{
        id: "career",
        name: "Career Builders",
        weight: 0.24,
        color: "#66d9b5",
        confidence: 0.76,
        goal: "Make growth visible",
        friction: "Unclear career value",
        grounding: "External research"
      },
      %{
        id: "privacy",
        name: "Privacy-sensitive",
        weight: 0.19,
        color: "#ef856b",
        confidence: 0.61,
        goal: "Stay in control",
        friction: "Default visibility",
        grounding: "Assumption + web"
      },
      %{
        id: "passive",
        name: "Passive learners",
        weight: 0.22,
        color: "#d5ba6b",
        confidence: 0.67,
        goal: "Finish required work",
        friction: "Low platform engagement",
        grounding: "Direct notes"
      },
      %{
        id: "collectors",
        name: "Certificate collectors",
        weight: 0.16,
        color: "#7d9cf5",
        confidence: 0.72,
        goal: "Accumulate signals",
        friction: "Course quality",
        grounding: "External research"
      },
      %{
        id: "skeptics",
        name: "Skeptical pragmatists",
        weight: 0.19,
        color: "#c59ae8",
        confidence: 0.58,
        goal: "See real value",
        friction: "Low trust in HR",
        grounding: "Assumption + web"
      }
    ]
  end

  defp patterns do
    [
      %{
        id: "career_signal",
        name: "Visible achievement signal",
        persona: "career",
        action: "adopt",
        probability: 0.68,
        confidence: 0.74
      },
      %{
        id: "privacy_default",
        name: "Default visibility feels like surveillance",
        persona: "privacy",
        action: "resist",
        probability: 0.72,
        confidence: 0.66
      },
      %{
        id: "manager_prompt",
        name: "Manager prompt breaks passive inertia",
        persona: "passive",
        action: "adopt",
        probability: 0.43,
        confidence: 0.63
      },
      %{
        id: "collect_signal",
        name: "Certificates are a portfolio signal",
        persona: "collectors",
        action: "share",
        probability: 0.61,
        confidence: 0.71
      },
      %{
        id: "proof_wait",
        name: "Wait for proof of career value",
        persona: "skeptics",
        action: "ignore",
        probability: 0.57,
        confidence: 0.58
      }
    ]
  end

  defp events do
    [
      %{
        day: 1,
        title: "Announcement",
        impact: "Awareness rises; most people wait.",
        action_effects: %{"adopt" => 0.02, "resist" => 0.02, "ignore" => 0.05, "share" => 0.0}
      },
      %{
        day: 14,
        title: "Certificate block appears",
        impact: "Privacy and value perceptions diverge.",
        action_effects: %{"adopt" => 0.03, "resist" => 0.12, "ignore" => 0.0, "share" => 0.02}
      },
      %{
        day: 30,
        title: "Manager prompt",
        impact: "Passive learners begin to move.",
        action_effects: %{"adopt" => 0.12, "resist" => 0.0, "ignore" => -0.08, "share" => 0.02}
      },
      %{
        day: 60,
        title: "Portfolio framing",
        impact: "Resistance softens when control is clear.",
        action_effects: %{"adopt" => 0.08, "resist" => -0.18, "ignore" => -0.04, "share" => 0.05}
      }
    ]
  end
end
