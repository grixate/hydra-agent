defmodule HydraAgent.Runtime.PubSub do
  @moduledoc """
  Runtime PubSub topics for control planes and LiveViews.
  """

  @pubsub HydraAgent.PubSub

  def workspace_topic(workspace_id), do: "workspace:#{workspace_id}"
  def run_topic(run_id), do: "run:#{run_id}"
  def conversation_topic(conversation_id), do: "conversation:#{conversation_id}"
  def simulation_topic(simulation_id), do: "simulation:#{simulation_id}"

  def subscribe_workspace(workspace_id),
    do: Phoenix.PubSub.subscribe(@pubsub, workspace_topic(workspace_id))

  def subscribe_run(run_id), do: Phoenix.PubSub.subscribe(@pubsub, run_topic(run_id))

  def subscribe_conversation(conversation_id),
    do: Phoenix.PubSub.subscribe(@pubsub, conversation_topic(conversation_id))

  def subscribe_simulation(simulation_id),
    do: Phoenix.PubSub.subscribe(@pubsub, simulation_topic(simulation_id))

  def broadcast_run_event(event) do
    broadcast(workspace_topic(event.workspace_id), {:run_event, event})
    broadcast(run_topic(event.run_id), {:run_event, event})
    :ok
  end

  def broadcast_turn(conversation, turn) do
    broadcast(
      workspace_topic(conversation.workspace_id),
      {:conversation_turn, conversation, turn}
    )

    broadcast(conversation_topic(conversation.id), {:conversation_turn, conversation, turn})
    :ok
  end

  def broadcast_conversation_delta(conversation, delta) do
    broadcast(
      workspace_topic(conversation.workspace_id),
      {:conversation_delta, conversation, delta}
    )

    broadcast(conversation_topic(conversation.id), {:conversation_delta, conversation, delta})
    :ok
  end

  def broadcast_run(run) do
    broadcast(workspace_topic(run.workspace_id), {:run_updated, run})
    broadcast(run_topic(run.id), {:run_updated, run})
    :ok
  end

  def broadcast_simulation(simulation) do
    broadcast(workspace_topic(simulation.workspace_id), {:simulation_updated, simulation})
    broadcast(simulation_topic(simulation.id), {:simulation_updated, simulation})
    :ok
  end

  def broadcast_simulation_tick(simulation, tick) do
    broadcast(workspace_topic(simulation.workspace_id), {:simulation_tick, simulation, tick})
    broadcast(simulation_topic(simulation.id), {:simulation_tick, simulation, tick})
    :ok
  end

  defp broadcast(topic, message), do: Phoenix.PubSub.broadcast(@pubsub, topic, message)
end
