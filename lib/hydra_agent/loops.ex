defmodule HydraAgent.Loops do
  @moduledoc """
  Durable, policy-governed loops.

  A loop is the reusable operating program that creates mission/run execution
  attempts, records decisions, and stops under explicit guardrails.
  """

  import Ecto.Query

  alias HydraAgent.Automations
  alias HydraAgent.Loops.Loop
  alias HydraAgent.Repo

  @recipes [
    %{
      "id" => "runtime_doctor_loop",
      "name" => "Runtime Doctor Loop",
      "slug" => "runtime-doctor-loop",
      "purpose" =>
        "Run operational checks, summarize runtime health, and surface incidents or attention items.",
      "trigger" => %{
        "type" => "cron",
        "cron_expression" => "*/30 * * * *",
        "timezone" => "Etc/UTC"
      },
      "body" => %{
        "skills" => ["runtime-doctor"],
        "state_scope" => "workspace",
        "output_behavior" => "attention_items"
      },
      "guardrails" => %{"max_child_runs_per_tick" => 2, "max_consecutive_no_progress" => 3}
    },
    %{
      "id" => "memory_curation_loop",
      "name" => "Memory Curation Loop",
      "slug" => "memory-curation-loop",
      "purpose" =>
        "Detect low-confidence or duplicate memories and draft provenance-backed curation proposals.",
      "trigger" => %{
        "type" => "cron",
        "cron_expression" => "0 */6 * * *",
        "timezone" => "Etc/UTC"
      },
      "body" => %{
        "skills" => ["memory-curation"],
        "state_scope" => "workspace",
        "output_behavior" => "draft_proposals"
      },
      "guardrails" => %{"max_child_runs_per_tick" => 3, "max_consecutive_no_progress" => 3}
    },
    %{
      "id" => "skill_improvement_loop",
      "name" => "Skill Improvement Loop",
      "slug" => "skill-improvement-loop",
      "purpose" =>
        "Review skill usage evidence, draft refine or prune proposals, and run safe eval-backed experiments.",
      "trigger" => %{"type" => "cron", "cron_expression" => "0 3 * * *", "timezone" => "Etc/UTC"},
      "body" => %{
        "skills" => ["skill-improvement"],
        "state_scope" => "workspace",
        "output_behavior" => "draft_skill_proposals"
      },
      "guardrails" => %{"max_child_runs_per_tick" => 2, "max_consecutive_no_progress" => 3}
    },
    %{
      "id" => "research_watch_loop",
      "name" => "Research Watch Loop",
      "slug" => "research-watch-loop",
      "purpose" =>
        "Monitor configured read-only sources and create provenance-backed research findings when meaningful changes appear.",
      "trigger" => %{
        "type" => "cron",
        "cron_expression" => "0 */4 * * *",
        "timezone" => "Etc/UTC"
      },
      "body" => %{
        "skills" => ["research-watch"],
        "state_scope" => "workspace",
        "output_behavior" => "knowledge_findings"
      },
      "guardrails" => %{"max_child_runs_per_tick" => 3, "max_consecutive_no_progress" => 4}
    },
    %{
      "id" => "handoff_digest_loop",
      "name" => "Handoff Digest Loop",
      "slug" => "handoff-digest-loop",
      "purpose" =>
        "Summarize blocked, awaiting-approval, and stale work into an operator handoff digest.",
      "trigger" => %{
        "type" => "cron",
        "cron_expression" => "0 9 * * 1-5",
        "timezone" => "Etc/UTC"
      },
      "body" => %{
        "skills" => ["handoff-digest"],
        "state_scope" => "workspace",
        "output_behavior" => "operator_digest"
      },
      "guardrails" => %{"max_child_runs_per_tick" => 1, "max_consecutive_no_progress" => 5}
    }
  ]

  def recipes, do: @recipes

  def list_loops(workspace_id, opts \\ []) do
    Loop
    |> where([loop], loop.workspace_id == ^workspace_id)
    |> maybe_filter_status(opt(opts, :status))
    |> maybe_filter_query(opt(opts, :q))
    |> order_by([loop], asc: loop.name)
    |> limit(^opt(opts, :limit, 100))
    |> preload([:mission, :supervisor_agent, :verifier_agent])
    |> Repo.all()
  end

  def get_loop!(id) do
    Loop
    |> Repo.get!(id)
    |> preload_loop()
  end

  def get_loop_for_workspace!(workspace_id, id) do
    Loop
    |> where(
      [loop],
      loop.workspace_id == ^normalize_id(workspace_id) and loop.id == ^normalize_id(id)
    )
    |> Repo.one!()
    |> preload_loop()
  end

  def create_loop(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> normalize_trigger()
      |> put_next_tick_at()

    %Loop{} |> Loop.changeset(attrs) |> Repo.insert()
  end

  def create_from_recipe(workspace_id, recipe_id, attrs \\ %{}) do
    attrs = stringify_keys(attrs)

    case Enum.find(@recipes, &(&1["id"] == recipe_id)) do
      nil ->
        {:error, %{"reason" => "loop_recipe_not_found", "recipe_id" => recipe_id}}

      recipe ->
        create_loop(%{
          "workspace_id" => workspace_id,
          "mission_id" => attrs["mission_id"],
          "supervisor_agent_id" => attrs["supervisor_agent_id"] || attrs["agent_id"],
          "verifier_agent_id" => attrs["verifier_agent_id"],
          "name" => attrs["name"] || recipe["name"],
          "slug" => attrs["slug"] || recipe["slug"],
          "status" => attrs["status"] || "draft",
          "purpose" => attrs["purpose"] || recipe["purpose"],
          "trigger" => Map.merge(recipe["trigger"], attrs["trigger"] || %{}),
          "body" => Map.merge(recipe["body"], attrs["body"] || %{}),
          "autonomy_level" => attrs["autonomy_level"] || "recommend",
          "budget" => attrs["budget"] || %{},
          "guardrails" => Map.merge(recipe["guardrails"], attrs["guardrails"] || %{}),
          "metadata" =>
            Map.merge(attrs["metadata"] || %{}, %{
              "recipe_id" => recipe_id,
              "created_from_recipe" => true
            })
        })
    end
  end

  def update_loop(%Loop{} = loop, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> normalize_trigger()
      |> maybe_refresh_next_tick_at(loop)

    loop |> Loop.changeset(attrs) |> Repo.update()
  end

  def pause_loop(%Loop{} = loop, attrs \\ %{}) do
    update_loop(loop, Map.merge(stringify_keys(attrs), %{"status" => "paused"}))
  end

  def resume_loop(%Loop{} = loop, attrs \\ %{}) do
    attrs = Map.merge(stringify_keys(attrs), %{"status" => "active", "last_error" => %{}})
    update_loop(loop, attrs)
  end

  def archive_loop(%Loop{} = loop, attrs \\ %{}) do
    update_loop(loop, Map.merge(stringify_keys(attrs), %{"status" => "archived"}))
  end

  def due_loops(now \\ now()) do
    Loop
    |> where([loop], loop.status == "active")
    |> where([loop], not is_nil(loop.next_tick_at) and loop.next_tick_at <= ^now)
    |> where([loop], is_nil(loop.lease_expires_at) or loop.lease_expires_at <= ^now)
    |> order_by([loop], asc: loop.next_tick_at)
    |> preload([:mission, :supervisor_agent, :verifier_agent])
    |> Repo.all()
  end

  def acquire_lease(%Loop{} = loop, owner, now \\ now(), ttl_ms \\ 300_000) do
    expires_at = DateTime.add(now, ttl_ms, :millisecond)

    query =
      Loop
      |> where([record], record.id == ^loop.id)
      |> where(
        [record],
        is_nil(record.lease_expires_at) or record.lease_expires_at <= ^now or
          record.lease_owner == ^owner
      )

    {count, _rows} =
      Repo.update_all(query,
        set: [lease_owner: owner, lease_expires_at: expires_at, updated_at: now]
      )

    if count == 1 do
      {:ok, get_loop!(loop.id)}
    else
      {:error, %{"reason" => "lease_conflict", "loop_id" => loop.id}}
    end
  end

  def release_lease(%Loop{} = loop, attrs \\ %{}) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.merge(%{"lease_owner" => nil, "lease_expires_at" => nil})
      |> put_next_tick_at()

    update_loop(loop, attrs)
  end

  def next_tick_at(loop_or_trigger, from \\ now())

  def next_tick_at(%Loop{} = loop, from) do
    next_tick_at(loop.trigger || %{}, from)
  end

  def next_tick_at(trigger, from) when is_map(trigger) do
    trigger = stringify_keys(trigger)

    case trigger["type"] || "manual" do
      "cron" ->
        Automations.next_run_at(
          trigger["cron_expression"],
          from,
          trigger["timezone"] || "Etc/UTC"
        )

      _type ->
        nil
    end
  end

  defp preload_loop(%Loop{} = loop) do
    Repo.preload(loop, [:mission, :supervisor_agent, :verifier_agent, runs: [:supervisor_agent]])
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, "all"), do: query
  defp maybe_filter_status(query, status), do: where(query, [loop], loop.status == ^status)

  defp maybe_filter_query(query, nil), do: query
  defp maybe_filter_query(query, ""), do: query

  defp maybe_filter_query(query, term) do
    like = "%#{term}%"
    where(query, [loop], ilike(loop.name, ^like) or ilike(loop.purpose, ^like))
  end

  defp normalize_trigger(%{"trigger" => trigger} = attrs) when is_map(trigger) do
    Map.put(attrs, "trigger", stringify_keys(trigger))
  end

  defp normalize_trigger(attrs), do: attrs

  defp put_next_tick_at(%{"trigger" => trigger} = attrs) do
    Map.put_new(attrs, "next_tick_at", next_tick_at(trigger, now()))
  end

  defp put_next_tick_at(attrs), do: attrs

  defp maybe_refresh_next_tick_at(attrs, loop) do
    cond do
      Map.has_key?(attrs, "next_tick_at") ->
        attrs

      Map.has_key?(attrs, "trigger") ->
        Map.put(attrs, "next_tick_at", next_tick_at(attrs["trigger"], now()))

      Map.get(attrs, "status") == "active" and is_nil(loop.next_tick_at) ->
        Map.put(attrs, "next_tick_at", next_tick_at(loop, now()))

      true ->
        attrs
    end
  end

  defp opt(opts, key, default \\ nil)
  defp opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)

  defp opt(opts, key, default) when is_map(opts),
    do: Map.get(opts, key) || Map.get(opts, to_string(key)) || default

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)
  defp normalize_id(id), do: id

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
