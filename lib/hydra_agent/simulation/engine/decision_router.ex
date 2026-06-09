defmodule HydraAgent.Simulation.Engine.DecisionRouter do
  @moduledoc """
  Four-tier decision router that avoids LLM calls unless uncertainty warrants it.
  """

  alias HydraAgent.Simulation.Agent.{Action, Persona, Traits}
  alias HydraAgent.Simulation.World.Event

  @negotiation_types [:negotiation_request, :alliance_proposal, :conflict_escalation]

  def classify(%Persona{} = persona, %Event{} = event, state) do
    cond do
      negotiation?(event, state) -> :negotiation
      complex?(persona, event, state) -> :complex
      emotional?(persona, event) -> :emotional
      true -> :routine
    end
  end

  def genuinely_torn?(%Traits{} = traits, %Event{} = event) do
    event.type
    |> Action.available_for()
    |> Enum.map(&{&1, Traits.personality_base(&1, traits)})
    |> Traits.compute_margin()
    |> Kernel.<=(0.15)
  end

  defp negotiation?(%Event{} = event, state) do
    event.type in @negotiation_types and not recent_negotiation?(state)
  end

  defp complex?(%Persona{} = persona, %Event{} = event, state) do
    novel?(event, state) and event.stakes > Map.get(state, :stakes_threshold, 0.7) and
      genuinely_torn?(persona.traits, event)
  end

  defp emotional?(%Persona{} = persona, %Event{} = event) do
    event.emotional_valence != :neutral and persona.traits.emotional_reactivity > 0.5 and
      (event.is_threat? or event.is_provocation? or event.is_windfall?)
  end

  defp novel?(%Event{} = event, state) do
    seen = Map.get(state, :seen_categories, %{})
    category = Action.category(event.type) |> Atom.to_string()
    Map.get(seen, category, 0) < Map.get(state, :novelty_threshold, 2)
  end

  defp recent_negotiation?(state), do: Map.get(state, :recent_negotiation?, false)
end
