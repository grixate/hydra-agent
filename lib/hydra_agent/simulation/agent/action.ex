defmodule HydraAgent.Simulation.Agent.Action do
  @moduledoc """
  Actions emitted by simulated agents.
  """

  @threat ~w(aggressive_response cautious_response seek_consensus protect_resources public_statement wait_and_observe)a
  @opportunity ~w(innovative_proposal seek_consensus public_statement private_negotiation wait_and_observe do_nothing)a
  @negotiation ~w(aggressive_response cautious_response seek_consensus private_negotiation defer_to_authority)a
  @neutral ~w(wait_and_observe seek_consensus do_nothing public_statement)a

  def available_for(event_type) do
    case category(event_type) do
      :threat -> @threat
      :opportunity -> @opportunity
      :negotiation -> @negotiation
      _ -> @neutral
    end
  end

  def category(type) when type in [:pr_crisis, :security_breach, :budget_pressure, :market_crash],
    do: :threat

  def category(type) when type in [:partnership_offer, :demand_surge, :innovation_breakthrough],
    do: :opportunity

  def category(type)
      when type in [:negotiation_request, :alliance_proposal, :conflict_escalation],
      do: :negotiation

  def category(_type), do: :neutral

  def volatility(action) when action in [:aggressive_response, :public_statement], do: 0.8
  def volatility(action) when action in [:innovative_proposal, :private_negotiation], do: 0.6
  def volatility(action) when action in [:seek_consensus, :protect_resources], do: 0.4
  def volatility(_action), do: 0.15
end
