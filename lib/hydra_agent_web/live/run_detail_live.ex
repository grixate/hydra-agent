defmodule HydraAgentWeb.RunDetailLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.Agent.Supervisor, as: AgentSupervisor
  alias HydraAgent.Memory
  alias HydraAgent.Runtime
  alias HydraAgent.Runtime.PubSub
  alias HydraAgent.Safety
  alias HydraAgent.Skills
  alias HydraAgent.Tools.Checkpoints
  alias HydraAgentWeb.ControlShell

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:run, nil)
     |> assign(:events, [])
     |> assign(:safety_events, [])
     |> assign(:checkpoints, [])
     |> assign(:timeline, [])
     |> assign(:worker_status, %{active: false})
     |> assign(:step_counts, %{})
     |> assign(:subscribed_run_id, nil)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    run_id = parse_id(id)

    socket =
      socket
      |> maybe_subscribe(run_id)
      |> load_run_state(run_id)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:run_event, _event}, socket),
    do: {:noreply, load_run_state(socket, socket.assigns.run.id)}

  def handle_info({:run_updated, _run}, socket),
    do: {:noreply, load_run_state(socket, socket.assigns.run.id)}

  @impl true
  def handle_event("start-run", _params, socket) do
    socket = socket.assigns.run |> Runtime.start_run() |> handle_run_result(socket, "Run started")
    {:noreply, load_run_state(socket, socket.assigns.run.id)}
  end

  def handle_event("pause-run", _params, socket) do
    socket =
      socket.assigns.run
      |> Runtime.pause_run(%{"actor" => "run_detail"})
      |> handle_run_result(socket, "Run paused")

    {:noreply, load_run_state(socket, socket.assigns.run.id)}
  end

  def handle_event("resume-run", _params, socket) do
    socket =
      socket.assigns.run
      |> Runtime.resume_run(%{"actor" => "run_detail"})
      |> handle_run_result(socket, "Run resumed")

    {:noreply, load_run_state(socket, socket.assigns.run.id)}
  end

  def handle_event("cancel-run", _params, socket) do
    socket =
      socket.assigns.run
      |> Runtime.cancel_run(%{"actor" => "run_detail"})
      |> handle_run_result(socket, "Run canceled")

    AgentSupervisor.stop_run_worker(socket.assigns.run.id)
    {:noreply, load_run_state(socket, socket.assigns.run.id)}
  end

  def handle_event("start-worker", _params, socket) do
    socket =
      case AgentSupervisor.start_run_worker(socket.assigns.run.id) do
        {:ok, _pid} -> put_flash(socket, :info, "Worker started")
        {:error, {:already_started, _pid}} -> put_flash(socket, :info, "Worker already running")
        {:error, reason} -> put_flash(socket, :error, "Worker start failed: #{inspect(reason)}")
      end

    {:noreply, load_run_state(socket, socket.assigns.run.id)}
  end

  def handle_event("stop-worker", _params, socket) do
    socket =
      case AgentSupervisor.stop_run_worker(socket.assigns.run.id) do
        :ok -> put_flash(socket, :info, "Worker stopped")
        {:error, :not_found} -> put_flash(socket, :info, "No worker was running")
        {:error, reason} -> put_flash(socket, :error, "Worker stop failed: #{inspect(reason)}")
      end

    {:noreply, load_run_state(socket, socket.assigns.run.id)}
  end

  def handle_event("draft-skill", _params, socket) do
    case Skills.propose_learning_from_run(socket.assigns.run, minimum_tool_count: 1) do
      {:ok, proposal} ->
        skill = Skills.get_skill!(proposal.target_skill_id)

        {:noreply,
         socket
         |> put_flash(:info, "Skill learning proposal ready")
         |> push_navigate(to: ~p"/control/skills/#{skill.id}?workspace_id=#{skill.workspace_id}")}

      {:error, error} ->
        {:noreply,
         put_flash(socket, :error, "Skill proposal failed: #{inspect(error_message(error))}")}
    end
  end

  def handle_event("draft-memory", _params, socket) do
    case Memory.propose_from_run(socket.assigns.run) do
      {:ok, _proposal} ->
        {:noreply,
         socket
         |> put_flash(:info, "Memory proposal ready")
         |> push_navigate(to: ~p"/control/memory?workspace_id=#{socket.assigns.run.workspace_id}")}

      {:error, %{} = error} ->
        {:noreply, put_flash(socket, :error, "Memory proposal failed: #{inspect(error)}")}
    end
  end

  def handle_event("approve-step", %{"id" => id}, socket) do
    socket =
      id
      |> get_step()
      |> Runtime.approve_run_step(%{"actor" => "run_detail"})
      |> handle_step_result(socket, "Step approved")

    {:noreply, load_run_state(socket, socket.assigns.run.id)}
  end

  def handle_event("reject-step", %{"id" => id}, socket) do
    socket =
      id
      |> get_step()
      |> Runtime.reject_run_step(%{"actor" => "run_detail"})
      |> handle_step_result(socket, "Step rejected")

    {:noreply, load_run_state(socket, socket.assigns.run.id)}
  end

  def handle_event("restore-checkpoint", %{"id" => id}, socket) do
    socket =
      case Checkpoints.restore_record(id, %{"workspace_root" => File.cwd!()}) do
        {:ok, _restored} ->
          put_flash(socket, :info, "Checkpoint restored")

        {:error, error} ->
          put_flash(socket, :error, "Checkpoint restore failed: #{inspect(error)}")
      end

    {:noreply, load_run_state(socket, socket.assigns.run.id)}
  end

  defp load_run_state(socket, run_id) do
    run = Runtime.get_run_detail!(run_id)
    safety_events = Safety.list_events(run.workspace_id, run_id: run.id, limit: 20)
    checkpoints = Checkpoints.list_records(run.workspace_id, run_id: run.id, limit: 20)

    socket
    |> assign(:page_title, "Run #{run.id}")
    |> assign(:run, run)
    |> assign(:events, run.events)
    |> assign(:safety_events, safety_events)
    |> assign(:checkpoints, checkpoints)
    |> assign(:timeline, timeline_entries(run.events, safety_events))
    |> assign(:worker_status, AgentSupervisor.run_worker_status(run.id))
    |> assign(:step_counts, Runtime.step_status_counts(run.id))
  end

  defp maybe_subscribe(socket, run_id) do
    case socket.assigns.subscribed_run_id do
      ^run_id ->
        socket

      _previous_run_id ->
        if connected?(socket), do: PubSub.subscribe_run(run_id)
        assign(socket, :subscribed_run_id, run_id)
    end
  end

  defp timeline_entries(events, safety_events) do
    run_events =
      Enum.map(events, fn event ->
        %{
          id: "run-event-#{event.id}",
          at: event.inserted_at,
          type: event.event_type,
          summary: event.summary,
          source: "runtime",
          run_step_id: event.run_step_id,
          payload: event.payload || %{}
        }
      end)

    safety =
      Enum.map(safety_events, fn event ->
        %{
          id: "safety-event-#{event.id}",
          at: event.inserted_at,
          type: event.action,
          summary: event.summary,
          source: "safety",
          run_step_id: event.run_step_id,
          payload: event.metadata || %{}
        }
      end)

    Enum.sort_by(run_events ++ safety, &{&1.at, &1.id}, fn
      {left_at, left_id}, {right_at, right_id} ->
        case DateTime.compare(left_at, right_at) do
          :lt -> true
          :gt -> false
          :eq -> left_id <= right_id
        end
    end)
  end

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp parse_id(_id), do: nil

  defp get_step(id), do: id |> parse_id() |> Runtime.get_run_step!()

  defp handle_run_result({:ok, _run}, socket, message), do: put_flash(socket, :info, message)

  defp handle_run_result({:error, changeset}, socket, _message),
    do: put_flash(socket, :error, "Run update failed: #{inspect(changeset.errors)}")

  defp handle_step_result({:ok, _step}, socket, message), do: put_flash(socket, :info, message)

  defp handle_step_result({:error, changeset}, socket, _message),
    do: put_flash(socket, :error, "Step update failed: #{inspect(changeset.errors)}")

  defp error_message(%Ecto.Changeset{} = changeset), do: changeset.errors
  defp error_message(error), do: error

  defp timestamp(nil), do: "n/a"

  defp timestamp(datetime) do
    Calendar.strftime(datetime, "%m-%d %H:%M:%S")
  end

  defp status_count(counts, status), do: Map.get(counts, status, 0)

  defp step_title(_run, nil), do: "run"

  defp step_title(run, step_id) do
    case Enum.find(run.steps, &(&1.id == step_id)) do
      nil -> "run"
      step -> "##{step.index} #{step.title}"
    end
  end

  defp compact_json(map) when map == %{}, do: ""

  defp compact_json(map) when is_map(map) do
    map
    |> Jason.encode!()
    |> String.slice(0, 240)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="run-detail" class="space-y-8">
      <ControlShell.header
        active={:mission}
        description={@run.goal}
        eyebrow="Run timeline"
        title={@run.title}
        workspace_id={@run.workspace_id}
        workspace_switcher={false}
      >
        <:actions>
          <button
            id="run-detail-start-run"
            type="button"
            phx-click="start-run"
            class="rounded-md border border-zinc-200 px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
          >
            Start
          </button>
          <button
            id="run-detail-pause-run"
            type="button"
            phx-click="pause-run"
            class="rounded-md border border-zinc-200 px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
          >
            Pause
          </button>
          <button
            id="run-detail-resume-run"
            type="button"
            phx-click="resume-run"
            class="rounded-md border border-zinc-200 px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
          >
            Resume
          </button>
          <button
            id="run-detail-cancel-run"
            type="button"
            phx-click="cancel-run"
            class="rounded-md border border-red-200 px-3 py-2 text-sm font-medium text-red-700 transition hover:border-red-400"
          >
            Cancel
          </button>
          <button
            id="run-detail-draft-skill"
            type="button"
            phx-click="draft-skill"
            class="rounded-md border border-zinc-200 px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
          >
            Learn Skill
          </button>
          <button
            id="run-detail-draft-memory"
            type="button"
            phx-click="draft-memory"
            class="rounded-md border border-zinc-200 px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
          >
            Draft Memory
          </button>
        </:actions>
      </ControlShell.header>

      <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-6">
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Status</p>
          <p class="mt-3 text-2xl font-semibold text-zinc-950">{@run.status}</p>
          <p class="mt-1 text-sm text-zinc-600">{@run.autonomy_level} autonomy</p>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Worker</p>
          <p class={[
            "mt-3 text-2xl font-semibold",
            @worker_status.active && "text-emerald-700",
            !@worker_status.active && "text-zinc-950"
          ]}>
            {if @worker_status.active, do: "active", else: "idle"}
          </p>
          <p class="mt-1 truncate text-sm text-zinc-600">
            {@worker_status.current_step_title || "no active step"}
          </p>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Steps</p>
          <p class="mt-3 text-2xl font-semibold text-zinc-950">{length(@run.steps)}</p>
          <p class="mt-1 text-sm text-zinc-600">
            {status_count(@step_counts, "completed")} completed / {status_count(
              @step_counts,
              "failed"
            )} failed
          </p>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Approvals</p>
          <p class="mt-3 text-2xl font-semibold text-zinc-950">
            {status_count(@step_counts, "awaiting_approval")}
          </p>
          <p class="mt-1 text-sm text-zinc-600">operator-gated</p>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Events</p>
          <p class="mt-3 text-2xl font-semibold text-zinc-950">{length(@timeline)}</p>
          <p class="mt-1 text-sm text-zinc-600">{length(@safety_events)} safety</p>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Loop</p>
          <%= if Ecto.assoc_loaded?(@run.loop) and @run.loop do %>
            <.link
              navigate={~p"/control/loops/#{@run.loop.id}?workspace_id=#{@run.workspace_id}"}
              class="mt-3 block truncate text-lg font-semibold text-zinc-950 hover:text-[var(--accent)]"
            >
              {@run.loop.name}
            </.link>
            <p class="mt-1 text-sm text-zinc-600">
              {get_in(@run.metadata || %{}, ["loop_stop_reason"]) || @run.loop.status}
            </p>
          <% else %>
            <p class="mt-3 text-2xl font-semibold text-zinc-950">none</p>
            <p class="mt-1 text-sm text-zinc-600">manual or mission run</p>
          <% end %>
        </div>
      </div>

      <div class="grid gap-6 xl:grid-cols-[0.78fr_1.22fr]">
        <section class="space-y-3">
          <div class="flex items-center justify-between">
            <h2 class="text-lg font-semibold text-zinc-950">Plan</h2>
            <div class="flex gap-2">
              <button
                id="run-detail-start-worker"
                type="button"
                phx-click="start-worker"
                class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
              >
                Start worker
              </button>
              <button
                id="run-detail-stop-worker"
                type="button"
                phx-click="stop-worker"
                class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
              >
                Stop worker
              </button>
            </div>
          </div>

          <div id="run-detail-steps" class="space-y-2">
            <div
              :for={step <- @run.steps}
              id={"run-detail-step-#{step.id}"}
              class="rounded-lg border border-zinc-200 bg-white p-4"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                    #{step.index} / {step.status}
                  </p>
                  <p class="mt-1 truncate text-sm font-semibold text-zinc-950">{step.title}</p>
                  <p class="mt-1 text-sm text-zinc-600">
                    {step.tool_name || "no tool"} / {step.side_effect_class}
                  </p>
                </div>
                <p class="text-xs text-zinc-500">attempts {step.attempt_count}</p>
              </div>

              <div :if={step.status == "awaiting_approval"} class="mt-3 flex gap-2">
                <button
                  id={"run-detail-approve-step-#{step.id}"}
                  type="button"
                  phx-click="approve-step"
                  phx-value-id={step.id}
                  class="rounded-md border border-emerald-200 px-2 py-1 text-xs font-medium text-emerald-700 transition hover:border-emerald-400"
                >
                  Approve
                </button>
                <button
                  id={"run-detail-reject-step-#{step.id}"}
                  type="button"
                  phx-click="reject-step"
                  phx-value-id={step.id}
                  class="rounded-md border border-red-200 px-2 py-1 text-xs font-medium text-red-700 transition hover:border-red-400"
                >
                  Reject
                </button>
              </div>
            </div>

            <div
              :if={@run.steps == []}
              class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
            >
              No steps planned.
            </div>
          </div>
        </section>

        <section class="space-y-3">
          <h2 class="text-lg font-semibold text-zinc-950">Timeline</h2>
          <div
            id="run-detail-timeline"
            class="overflow-hidden rounded-lg border border-zinc-200 bg-white"
          >
            <div
              :for={entry <- @timeline}
              id={"run-detail-#{entry.id}"}
              class="grid gap-3 border-b border-zinc-100 px-4 py-4 last:border-b-0 md:grid-cols-[110px_110px_1fr]"
            >
              <p class="text-xs font-medium text-zinc-500">{timestamp(entry.at)}</p>
              <div>
                <p class={[
                  "inline-flex rounded-md px-2 py-1 text-xs font-semibold",
                  entry.source == "safety" && "bg-amber-50 text-amber-800",
                  entry.source != "safety" && "bg-zinc-100 text-zinc-700"
                ]}>
                  {entry.source}
                </p>
              </div>
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <p class="text-sm font-semibold text-zinc-950">{entry.type}</p>
                  <p class="text-xs text-zinc-500">{step_title(@run, entry.run_step_id)}</p>
                </div>
                <p class="mt-1 text-sm text-zinc-600">{entry.summary}</p>
                <p :if={compact_json(entry.payload) != ""} class="mt-2 truncate text-xs text-zinc-500">
                  {compact_json(entry.payload)}
                </p>
              </div>
            </div>

            <div :if={@timeline == []} class="px-4 py-8 text-sm text-zinc-500">
              No timeline events yet.
            </div>
          </div>
        </section>
      </div>

      <section class="space-y-3">
        <h2 class="text-lg font-semibold text-zinc-950">Checkpoints</h2>
        <div
          id="run-detail-checkpoints"
          class="overflow-hidden rounded-lg border border-zinc-200 bg-white"
        >
          <div
            :for={checkpoint <- @checkpoints}
            id={"run-detail-checkpoint-#{checkpoint.id}"}
            class="grid gap-3 border-b border-zinc-100 px-4 py-3 text-sm last:border-b-0 md:grid-cols-[1fr_140px_120px]"
          >
            <div class="min-w-0">
              <p class="truncate font-medium text-zinc-950">
                {checkpoint.relative_path || checkpoint.path}
              </p>
              <p class="mt-1 truncate text-xs text-zinc-500">
                {checkpoint.tool_name || "tool"} / {timestamp(checkpoint.inserted_at)}
              </p>
            </div>
            <span class="text-zinc-600">
              {if checkpoint.restored_at, do: "restored", else: "available"}
            </span>
            <button
              type="button"
              phx-click="restore-checkpoint"
              phx-value-id={checkpoint.id}
              class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
            >
              Restore
            </button>
          </div>
          <div :if={@checkpoints == []} class="px-4 py-8 text-sm text-zinc-500">
            No file checkpoints recorded for this run.
          </div>
        </div>
      </section>
    </section>
    """
  end
end
