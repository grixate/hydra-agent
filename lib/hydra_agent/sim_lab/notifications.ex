defmodule HydraAgent.SimLab.Notifications do
  @moduledoc """
  Lightweight PubSub notifications for the optional simulation domain.

  The topic contains only database identifiers and job state; raw study text
  and research queries are never broadcast.
  """

  @pubsub HydraAgent.PubSub

  def study_topic(study_id), do: "sim_lab:study:#{study_id}"

  def subscribe(study_id), do: Phoenix.PubSub.subscribe(@pubsub, study_topic(study_id))

  def broadcast(study_id, event) when is_map(event) do
    Phoenix.PubSub.broadcast(@pubsub, study_topic(study_id), {:sim_lab_update, event})
  end
end
