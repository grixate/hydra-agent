defmodule HydraAgent.Simulation.Agent.Persona do
  @moduledoc """
  Neutral simulated participant persona.
  """

  alias HydraAgent.Simulation.Agent.Traits

  defstruct name: "Participant",
            role: "Participant",
            backstory: "",
            domain: "general",
            traits: %Traits{}

  def new(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    %__MODULE__{
      name: attrs["name"] || "Participant",
      role: attrs["role"] || "Participant",
      backstory: attrs["backstory"] || "",
      domain: attrs["domain"] || "general",
      traits: Traits.new(attrs["traits"] || %{})
    }
  end

  def to_map(%__MODULE__{} = persona) do
    %{
      "name" => persona.name,
      "role" => persona.role,
      "backstory" => persona.backstory,
      "domain" => persona.domain,
      "traits" => Map.from_struct(persona.traits)
    }
  end

  def archetypes do
    [
      %__MODULE__{
        name: "Cautious Operator",
        role: "Operations stakeholder",
        domain: "operations",
        backstory: "Values reliability, practical tradeoffs, and controlled change.",
        traits: %Traits{conscientiousness: 0.85, risk_tolerance: 0.25, analytical_depth: 0.75}
      },
      %__MODULE__{
        name: "Visionary Sponsor",
        role: "Executive sponsor",
        domain: "leadership",
        backstory: "Looks for upside, speed, and strategic leverage.",
        traits: %Traits{openness: 0.9, innovation_bias: 0.9, risk_tolerance: 0.75}
      },
      %__MODULE__{
        name: "Skeptical Analyst",
        role: "Analyst",
        domain: "finance",
        backstory: "Tests claims against evidence, cost, and downside risk.",
        traits: %Traits{analytical_depth: 0.95, conscientiousness: 0.8, risk_tolerance: 0.2}
      },
      %__MODULE__{
        name: "Competitive Peer",
        role: "External competitor",
        domain: "market",
        backstory: "Responds quickly to openings and pressure.",
        traits: %Traits{competitive_drive: 0.95, extraversion: 0.75, agreeableness: 0.2}
      },
      %__MODULE__{
        name: "Consensus Builder",
        role: "Team lead",
        domain: "people",
        backstory: "Tries to preserve alignment and reduce social friction.",
        traits: %Traits{consensus_seeking: 0.9, agreeableness: 0.85, emotional_reactivity: 0.55}
      }
    ]
  end

  def generated_population(count, seed \\ 1) do
    archetypes = archetypes()

    for index <- 0..(count - 1) do
      base = Enum.at(archetypes, rem(index, length(archetypes)))
      traits = Traits.apply_noise(base.traits, seed + index)
      %{base | name: "#{base.name} #{index + 1}", traits: traits}
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
