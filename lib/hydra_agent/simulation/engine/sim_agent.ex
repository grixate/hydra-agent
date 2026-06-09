defmodule HydraAgent.Simulation.Engine.SimAgent do
  @moduledoc """
  Pure simulated-agent decision logic used by the tick runner.
  """

  alias HydraAgent.Simulation.Agent.{Action, Persona, Traits}
  alias HydraAgent.Simulation.Engine.DecisionRouter
  alias HydraAgent.Simulation.World.Event

  def decide(%Persona{} = persona, %Event{} = event, state, config) do
    tier =
      DecisionRouter.classify(persona, event, %{
        seen_categories: Map.get(state, "seen_categories", %{}),
        novelty_threshold: config["novelty_threshold"],
        stakes_threshold: config["stakes_threshold"],
        recent_negotiation?: Map.get(state, "recent_negotiation?", false)
      })

    case tier do
      :routine -> {:ok, routine_action(persona, event, state), state}
      :emotional -> {:ok, emotional_action(persona, event), state}
      :complex -> {:llm, :cheap, llm_request(persona, event, state, :cheap), state}
      :negotiation -> {:llm, :frontier, llm_request(persona, event, state, :frontier), state}
    end
  end

  def routine_action(%Persona{} = persona, %Event{} = event, state) do
    seed = :erlang.phash2({persona.name, event.id, Map.get(state, "decision_count", 0)})

    action =
      event.type
      |> Action.available_for()
      |> Enum.map(&{&1, Traits.personality_base(&1, persona.traits)})
      |> Traits.weighted_choice(seed)

    %{
      "action" => Atom.to_string(action),
      "method" => "rules_engine",
      "tier" => "routine",
      "reasoning" => "Selected by deterministic personality weights."
    }
  end

  def emotional_action(%Persona{} = persona, %Event{} = event) do
    action =
      cond do
        event.is_threat? and persona.traits.competitive_drive > 0.65 -> :aggressive_response
        event.is_threat? -> :cautious_response
        event.is_windfall? and persona.traits.risk_tolerance > 0.55 -> :innovative_proposal
        true -> :seek_consensus
      end

    %{
      "action" => Atom.to_string(action),
      "method" => "emotional",
      "tier" => "emotional",
      "reasoning" => "Selected by emotional fast path."
    }
  end

  def apply_decision_state(state, %Event{} = event, decision) do
    category = Action.category(event.type) |> Atom.to_string()
    seen = Map.update(Map.get(state, "seen_categories", %{}), category, 1, &(&1 + 1))
    recent_negotiation? = decision["action"] == "private_negotiation"

    state
    |> Map.put("seen_categories", seen)
    |> Map.put("recent_negotiation?", recent_negotiation?)
    |> Map.update("decision_count", 1, &(&1 + 1))
    |> Map.put("last_action", decision)
  end

  defp llm_request(persona, event, state, tier) do
    %{
      persona: persona,
      event: event,
      state: state,
      tier: tier,
      messages: [
        %{
          "role" => "system",
          "content" =>
            "You are a simulated participant. Return compact JSON with action and reasoning."
        },
        %{
          "role" => "user",
          "content" =>
            "Persona: #{persona.name}, #{persona.role}. Event: #{event.description}. Stakes: #{event.stakes}. Choose an action from #{inspect(Action.available_for(event.type))}."
        }
      ]
    }
  end
end
