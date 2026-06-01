defmodule HydraAgent.Skills.LearningWorker do
  @moduledoc """
  Background skill-learning scanner.

  The worker only creates governed improvement proposals. Activation is still
  handled by `HydraAgent.Skills` and its autonomy/eval policy.
  """

  use GenServer

  import Ecto.Query

  alias HydraAgent.{Repo, Rooms, Runtime, Skills}
  alias HydraAgent.Rooms.Room
  alias HydraAgent.Runtime.{Conversation, Run}
  require Logger

  @default_interval_ms 120_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      minimum_tool_count: Keyword.get(opts, :minimum_tool_count, 5),
      minimum_turn_count: Keyword.get(opts, :minimum_turn_count, 4),
      minimum_message_count: Keyword.get(opts, :minimum_message_count, 4)
    }

    schedule_tick(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:learn, state) do
    learn_due(state)
    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  def learn_due(state \\ %{}) do
    state =
      state
      |> Map.put_new(:minimum_tool_count, 5)
      |> Map.put_new(:minimum_turn_count, 4)
      |> Map.put_new(:minimum_message_count, 4)

    workspace_ids = Runtime.list_workspace_ids()

    run_results =
      workspace_ids
      |> Enum.flat_map(&eligible_runs(&1, state))
      |> Enum.map(fn run ->
        case Skills.propose_learning_from_run(run, minimum_tool_count: state.minimum_tool_count) do
          {:ok, proposal} -> proposal
          {:error, error} -> error
        end
      end)

    conversation_results =
      workspace_ids
      |> Enum.flat_map(&eligible_conversations(&1, state))
      |> Enum.map(fn conversation ->
        case Skills.propose_learning_from_conversation(conversation,
               minimum_turn_count: state.minimum_turn_count
             ) do
          {:ok, proposal} -> proposal
          {:error, error} -> error
        end
      end)

    room_results =
      workspace_ids
      |> Enum.flat_map(&eligible_rooms(&1, state))
      |> Enum.map(fn room ->
        case Skills.propose_learning_from_room(room,
               minimum_message_count: state.minimum_message_count
             ) do
          {:ok, proposal} -> proposal
          {:error, error} -> error
        end
      end)

    run_results ++ conversation_results ++ room_results
  rescue
    error ->
      Logger.warning("skill learning worker skipped tick: #{Exception.message(error)}")
      []
  end

  defp eligible_runs(workspace_id, state) do
    minimum_tool_count = Map.get(state, :minimum_tool_count, 5)

    Run
    |> where([run], run.workspace_id == ^workspace_id and run.status in ["completed", "failed"])
    |> order_by([run], desc: run.updated_at)
    |> limit(20)
    |> preload([:steps, :supervisor_agent])
    |> Repo.all()
    |> Enum.reject(&existing_learning_proposal?/1)
    |> Enum.filter(fn run ->
      Enum.count(run.steps, fn step -> step.tool_name end) >= minimum_tool_count or
        recovery_run?(run)
    end)
  end

  defp eligible_conversations(workspace_id, state) do
    minimum_turn_count = Map.get(state, :minimum_turn_count, 4)

    Conversation
    |> where(
      [conversation],
      conversation.workspace_id == ^workspace_id and conversation.status == "active"
    )
    |> order_by([conversation], desc: conversation.updated_at)
    |> limit(20)
    |> preload([:agent, :turns])
    |> Repo.all()
    |> Enum.reject(&existing_conversation_learning_proposal?/1)
    |> Enum.filter(&(length(&1.turns || []) >= minimum_turn_count))
  end

  defp eligible_rooms(workspace_id, state) do
    minimum_message_count = Map.get(state, :minimum_message_count, 4)

    Room
    |> where([room], room.workspace_id == ^workspace_id and room.status == "active")
    |> order_by([room], desc: room.updated_at)
    |> limit(20)
    |> Repo.all()
    |> Enum.reject(&existing_room_learning_proposal?/1)
    |> Enum.filter(fn room ->
      room
      |> Rooms.list_messages(limit: minimum_message_count)
      |> length()
      |> Kernel.>=(minimum_message_count)
    end)
  end

  defp recovery_run?(run) do
    run.steps
    |> List.wrap()
    |> Enum.any?(fn step ->
      step.status in ["failed", "blocked"] or map_size(step.error || %{}) > 0 or
        map_size(step.approval || %{}) > 0
    end)
  end

  defp existing_learning_proposal?(run) do
    HydraAgent.Skills.ImprovementProposal
    |> where([proposal], proposal.source_run_id == ^run.id)
    |> Repo.exists?()
  end

  defp existing_conversation_learning_proposal?(conversation) do
    HydraAgent.Skills.ImprovementProposal
    |> where([proposal], proposal.source_conversation_id == ^conversation.id)
    |> Repo.exists?()
  end

  defp existing_room_learning_proposal?(room) do
    HydraAgent.Skills.ImprovementProposal
    |> where([proposal], proposal.source_room_id == ^room.id)
    |> Repo.exists?()
  end

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :learn, interval_ms)
end
