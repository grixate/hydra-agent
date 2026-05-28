defmodule HydraAgent.Automations do
  @moduledoc """
  Workspace-scoped scheduled automations.

  Automations send prompts to an agent on a cron schedule and persist the
  resulting conversation turns through the normal agent chat path.
  """

  import Ecto.Query

  alias HydraAgent.AgentChat
  alias HydraAgent.Automations.Automation
  alias HydraAgent.Connectors
  alias HydraAgent.Repo
  alias HydraAgent.Runtime

  @recipes [
    %{
      "id" => "daily_briefing",
      "name" => "Daily Briefing",
      "slug" => "daily-briefing",
      "cron_expression" => "0 8 * * *",
      "prompt" =>
        "Prepare a concise daily briefing from calendar, email highlights, open reminders, and saved research notes. Deliver it to the configured room.",
      "required_connectors" => ["email", "calendar", "notes"],
      "delivery_targets" => ["room", "telegram"]
    },
    %{
      "id" => "research_watch",
      "name" => "Research Watch",
      "slug" => "research-watch",
      "cron_expression" => "0 */6 * * *",
      "prompt" =>
        "Check configured research topics and sources, summarize what changed, cite provenance, and save durable findings to the knowledge base.",
      "required_connectors" => ["youtube", "notes"],
      "delivery_targets" => ["room", "notion", "notes"]
    },
    %{
      "id" => "content_draft",
      "name" => "Content Draft",
      "slug" => "content-draft",
      "cron_expression" => "0 10 * * 1",
      "prompt" =>
        "Turn the latest approved research notes into draft social, newsletter, or long-form content. Do not publish without approval.",
      "required_connectors" => ["notes", "x", "linkedin"],
      "delivery_targets" => ["room"]
    },
    %{
      "id" => "weekly_content_pipeline",
      "name" => "Weekly Content Pipeline",
      "slug" => "weekly-content-pipeline",
      "cron_expression" => "0 9 * * 1",
      "prompt" =>
        "Review approved research, notes, and previous drafts. Propose a weekly content plan with draft posts for each configured channel, but do not publish.",
      "required_connectors" => ["notes", "x", "linkedin", "youtube"],
      "delivery_targets" => ["room", "notes"]
    },
    %{
      "id" => "social_monitoring",
      "name" => "Social Monitoring",
      "slug" => "social-monitoring",
      "cron_expression" => "0 */4 * * *",
      "prompt" =>
        "Monitor configured social and media sources for relevant mentions, opportunities, and risks. Summarize changes and draft optional responses for approval.",
      "required_connectors" => ["x", "linkedin", "youtube", "notes"],
      "delivery_targets" => ["room"]
    },
    %{
      "id" => "meeting_prep",
      "name" => "Meeting Prep",
      "slug" => "meeting-prep",
      "cron_expression" => "*/30 * * * *",
      "prompt" =>
        "Look ahead for upcoming meetings, collect relevant notes and recent correspondence, and draft a prep brief.",
      "required_connectors" => ["calendar", "email", "notes"],
      "delivery_targets" => ["room", "telegram"]
    },
    %{
      "id" => "post_meeting_follow_up",
      "name" => "Post Meeting Follow-Up",
      "slug" => "post-meeting-follow-up",
      "cron_expression" => "15 * * * *",
      "prompt" =>
        "Find recently completed meetings, summarize decisions, extract next actions, and draft follow-up messages without sending them.",
      "required_connectors" => ["calendar", "email", "notes"],
      "delivery_targets" => ["room", "telegram", "notes"]
    },
    %{
      "id" => "inbox_triage",
      "name" => "Inbox Triage",
      "slug" => "inbox-triage",
      "cron_expression" => "0 */2 * * *",
      "prompt" =>
        "Review recent inbox items, classify urgency, draft replies when useful, and ask for approval before sending anything.",
      "required_connectors" => ["email"],
      "delivery_targets" => ["room"]
    },
    %{
      "id" => "follow_up_reminders",
      "name" => "Follow-Up Reminders",
      "slug" => "follow-up-reminders",
      "cron_expression" => "0 16 * * 1-5",
      "prompt" =>
        "Review open follow-ups and waiting-on items. Draft a short reminder list and proposed messages for approval.",
      "required_connectors" => ["email", "notes"],
      "delivery_targets" => ["room", "telegram"]
    },
    %{
      "id" => "reminders",
      "name" => "Reminders",
      "slug" => "reminders",
      "cron_expression" => "0 9 * * 1-5",
      "prompt" =>
        "Review saved reminders, due tasks, and important stale items. Produce a prioritized reminder brief for the configured room.",
      "required_connectors" => ["calendar", "notes"],
      "delivery_targets" => ["room", "telegram"]
    },
    %{
      "id" => "weekly_research_digest",
      "name" => "Weekly Research Digest",
      "slug" => "weekly-research-digest",
      "cron_expression" => "0 11 * * 5",
      "prompt" =>
        "Summarize the week's research watch findings, highlight source-backed changes, and propose follow-up research tasks.",
      "required_connectors" => ["youtube", "notes", "notion"],
      "delivery_targets" => ["room", "notion", "notes"]
    }
  ]

  def recipes, do: @recipes

  def list_automations(workspace_id, opts \\ []) do
    Automation
    |> where([automation], automation.workspace_id == ^workspace_id)
    |> maybe_filter_status(opt(opts, :status))
    |> order_by([automation], asc: automation.name)
    |> Repo.all()
  end

  def get_automation!(id), do: Repo.get!(Automation, id) |> Repo.preload([:agent])

  def create_automation(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put_new(
        "next_run_at",
        next_run_at(
          attrs["cron_expression"] || attrs[:cron_expression],
          now(),
          attrs["timezone"] || attrs[:timezone] || "Etc/UTC"
        )
      )

    %Automation{} |> Automation.changeset(attrs) |> Repo.insert()
  end

  def create_from_recipe(workspace_id, recipe_id, attrs) do
    attrs = stringify_keys(attrs)

    case Enum.find(@recipes, &(&1["id"] == recipe_id)) do
      nil ->
        {:error, %{"reason" => "automation_recipe_not_found", "recipe_id" => recipe_id}}

      recipe ->
        case attrs["agent_id"] do
          nil ->
            {:error, %{"reason" => "automation_recipe_agent_required"}}

          agent_id ->
            delivery_target = attrs["delivery_target"] || "room"

            create_automation(%{
              "workspace_id" => workspace_id,
              "agent_id" => agent_id,
              "name" => attrs["name"] || recipe["name"],
              "slug" => attrs["slug"] || recipe["slug"],
              "status" => attrs["status"] || "active",
              "cron_expression" => attrs["cron_expression"] || recipe["cron_expression"],
              "timezone" => attrs["timezone"] || "Etc/UTC",
              "prompt" => attrs["prompt"] || recipe["prompt"],
              "metadata" =>
                Map.merge(attrs["metadata"] || %{}, %{
                  "recipe_id" => recipe_id,
                  "delivery_target" => delivery_target,
                  "room_id" => attrs["room_id"],
                  "required_connectors" => recipe["required_connectors"],
                  "permission_preset" => attrs["permission_preset"] || "approve_writes"
                })
            })
        end
    end
  end

  def update_automation(%Automation{} = automation, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> maybe_refresh_next_run_at()

    automation |> Automation.changeset(attrs) |> Repo.update()
  end

  def clear_last_error(%Automation{} = automation) do
    update_automation(automation, %{"last_error" => %{}})
  end

  def readiness(%Automation{} = automation) do
    readiness(automation, Connectors.list_accounts(automation.workspace_id))
  end

  def readiness(%Automation{} = automation, connector_accounts)
      when is_list(connector_accounts) do
    required_connectors = required_connectors(automation)
    accounts_by_provider = Map.new(connector_accounts, &{&1.provider, &1})

    checks =
      Enum.map(required_connectors, fn provider ->
        connector_readiness_check(provider, accounts_by_provider[provider])
      end)

    blockers = Enum.filter(checks, &(&1["severity"] == "error"))
    warnings = Enum.filter(checks, &(&1["severity"] == "warning"))

    %{
      "status" => automation_readiness_status(blockers, warnings),
      "required_connectors" => required_connectors,
      "checks" => checks,
      "blockers" => blockers,
      "warnings" => warnings
    }
  end

  def due_automations(now \\ now()) do
    Automation
    |> where([automation], automation.status == "active")
    |> where([automation], not is_nil(automation.next_run_at) and automation.next_run_at <= ^now)
    |> order_by([automation], asc: automation.next_run_at)
    |> preload([:agent])
    |> Repo.all()
  end

  def run_due_automations(now \\ now()) do
    now
    |> due_automations()
    |> Enum.map(&run_automation(&1, now))
  end

  def run_automation(%Automation{} = automation, now \\ now()) do
    automation = Repo.preload(automation, [:agent])

    with :ok <- ensure_automation_ready(automation, now),
         {:ok, run} <- create_automation_run(automation, now) do
      execute_automation_run(automation, run, now)
    end
  end

  defp create_automation_run(automation, now) do
    Runtime.create_run(%{
      workspace_id: automation.workspace_id,
      supervisor_agent_id: automation.agent_id,
      title: "Automation: #{automation.name}",
      goal: automation.prompt,
      status: "planned",
      metadata: %{
        "kind" => "automation_execution",
        "automation_id" => automation.id,
        "automation_slug" => automation.slug,
        "scheduled_for" => DateTime.to_iso8601(now)
      }
    })
  end

  defp execute_automation_run(automation, run, now) do
    case Runtime.start_run(run) do
      {:ok, running_run} ->
        execute_started_automation_run(automation, running_run, now)

      {:error, error} ->
        fail_automation_run(automation, run, now, error)
    end
  end

  defp execute_started_automation_run(automation, run, now) do
    with {:ok, conversation} <- start_automation_conversation(automation, run),
         {:ok, response} <-
           AgentChat.respond(conversation, automation.prompt, source: "automation") do
      complete_automation_run(automation, run, now, response)
    else
      {:error, error} -> fail_automation_run(automation, run, now, error)
    end
  end

  defp complete_automation_run(automation, run, now, response) do
    run = Runtime.get_run!(run.id)

    {:ok, _completed_run} =
      Runtime.complete_run(run, %{
        "result" => %{
          "conversation_id" => response.conversation.id,
          "assistant_turn_id" => response.assistant_turn.id
        },
        "metadata" =>
          Map.merge(run.metadata || %{}, %{
            "conversation_id" => response.conversation.id,
            "assistant_turn_id" => response.assistant_turn.id
          })
      })

    update_automation(automation, %{
      "last_run_at" => now,
      "next_run_at" => next_run_at(automation.cron_expression, now, automation.timezone),
      "last_error" => %{},
      "metadata" =>
        Map.merge(automation.metadata || %{}, %{
          "last_run_id" => run.id,
          "last_conversation_id" => response.conversation.id,
          "last_assistant_turn_id" => response.assistant_turn.id
        })
    })
  end

  defp fail_automation_run(automation, run, now, error) do
    normalized_error = normalize_error(error)
    run = Runtime.get_run!(run.id)
    {:ok, _failed_run} = Runtime.fail_run(run, %{"result" => %{"error" => normalized_error}})

    update_automation(automation, %{
      "last_run_at" => now,
      "next_run_at" => next_run_at(automation.cron_expression, now, automation.timezone),
      "last_error" => normalized_error,
      "metadata" => Map.merge(automation.metadata || %{}, %{"last_run_id" => run.id})
    })
  end

  defp fail_automation_before_run(automation, now, error) do
    update_automation(automation, %{
      "last_run_at" => now,
      "next_run_at" => next_run_at(automation.cron_expression, now, automation.timezone),
      "last_error" => normalize_error(error)
    })
  end

  defp ensure_automation_ready(automation, now) do
    case readiness(automation) do
      %{"status" => "blocked"} = readiness ->
        fail_automation_before_run(automation, now, %{
          "reason" => "automation_connector_readiness_blocked",
          "message" => "Required connectors must be configured before this automation can run.",
          "readiness" => readiness
        })

      _readiness ->
        :ok
    end
  end

  defp start_automation_conversation(automation, run) do
    AgentChat.start_conversation(automation.agent, %{
      title: "Automation: #{automation.name}",
      channel: "automation",
      metadata: %{"automation_id" => automation.id, "automation_run_id" => run.id}
    })
  end

  def next_run_at(expression, from \\ now())

  def next_run_at(nil, _from), do: nil
  def next_run_at(expression, from), do: next_run_at(expression, from, "Etc/UTC")

  def next_run_at(expression, from, timezone) when is_binary(expression) do
    timezone = timezone || "Etc/UTC"

    with {:ok, local_from} <- DateTime.shift_zone(from, timezone),
         {:ok, cron} <- Crontab.CronExpression.Parser.parse(expression),
         {:ok, naive} <- Crontab.Scheduler.get_next_run_date(cron, DateTime.to_naive(local_from)),
         {:ok, local_next} <- DateTime.from_naive(naive, timezone),
         {:ok, utc_next} <- DateTime.shift_zone(local_next, "Etc/UTC") do
      utc_next
    else
      _error -> nil
    end
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status),
    do: where(query, [automation], automation.status == ^status)

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key) || Map.get(opts, to_string(key))

  defp maybe_refresh_next_run_at(%{"cron_expression" => expression} = attrs) do
    Map.put_new(
      attrs,
      "next_run_at",
      next_run_at(expression, now(), attrs["timezone"] || "Etc/UTC")
    )
  end

  defp maybe_refresh_next_run_at(attrs), do: attrs

  defp normalize_error(%Ecto.Changeset{} = changeset) do
    %{"reason" => "changeset_error", "errors" => changeset_errors(changeset)}
  end

  defp normalize_error(error) when is_map(error), do: error
  defp normalize_error(error), do: %{"reason" => inspect(error)}

  defp required_connectors(%Automation{} = automation) do
    automation
    |> metadata_value("required_connectors")
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp connector_readiness_check(provider, nil) do
    %{
      "provider" => provider,
      "status" => "missing",
      "severity" => "error",
      "reason" => "connector_missing",
      "findings" => [%{"reason" => "connector_missing"}]
    }
  end

  defp connector_readiness_check(provider, account) do
    readiness = Connectors.setup_readiness(account)
    severity = connector_readiness_severity(readiness["status"])

    %{
      "provider" => provider,
      "account_id" => account.id,
      "display_name" => account.display_name,
      "status" => readiness["status"],
      "severity" => severity,
      "reason" => connector_readiness_reason(readiness["status"]),
      "credential" => readiness["credential"],
      "missing_required_config" => readiness["missing_required_config"],
      "missing_recommended_config" => readiness["missing_recommended_config"],
      "findings" => readiness["findings"]
    }
  end

  defp connector_readiness_severity("needs_attention"), do: "error"
  defp connector_readiness_severity("setup_pending"), do: "warning"
  defp connector_readiness_severity(_status), do: "ok"

  defp connector_readiness_reason("needs_attention"), do: "connector_needs_attention"
  defp connector_readiness_reason("setup_pending"), do: "connector_setup_pending"
  defp connector_readiness_reason(_status), do: "connector_ready"

  defp automation_readiness_status([_blocker | _], _warnings), do: "blocked"
  defp automation_readiness_status([], [_warning | _]), do: "setup_pending"
  defp automation_readiness_status([], []), do: "ready"

  defp metadata_value(%{metadata: metadata}, key) when is_map(metadata),
    do: metadata[to_string(key)] || metadata[key]

  defp metadata_value(_record, _key), do: nil

  defp blank?(value), do: is_nil(value) or value == ""

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
