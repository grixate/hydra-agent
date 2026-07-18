defmodule HydraAgent.Automations do
  @moduledoc """
  Workspace-scoped scheduled automations.

  Automations send prompts to an agent on a cron schedule and persist the
  resulting conversation turns through the normal agent chat path.
  """

  import Ecto.Query

  alias HydraAgent.AgentChat
  alias HydraAgent.Automations.{Automation, AutomationExecution}
  alias HydraAgent.Connectors
  alias HydraAgent.Repo
  alias HydraAgent.Runtime

  @in_flight_execution_statuses ~w(claimed running)

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

  def list_executions(workspace_id, opts \\ []) do
    AutomationExecution
    |> where([execution], execution.workspace_id == ^workspace_id)
    |> maybe_filter_execution_automation(opt(opts, :automation_id))
    |> maybe_filter_status(opt(opts, :status))
    |> order_by([execution], desc: execution.scheduled_for, desc: execution.id)
    |> preload([:automation, :run])
    |> Repo.all()
  end

  def get_execution!(id) do
    AutomationExecution
    |> Repo.get!(id)
    |> Repo.preload([:automation, :run])
  end

  def get_automation!(id), do: Repo.get!(Automation, id) |> Repo.preload([:agent])

  def get_automation_for_workspace(workspace_id, id) do
    Automation
    |> where(
      [automation],
      automation.workspace_id == ^normalize_id(workspace_id) and
        automation.id == ^normalize_id(id)
    )
    |> Repo.one()
    |> maybe_preload_agent()
  end

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
    |> Enum.reduce([], fn automation, results ->
      case claim_due_automation(automation, now) do
        {:ok, execution, claimed_automation} ->
          [execute_claimed_automation(claimed_automation, execution) | results]

        {:skip, _reason} ->
          results

        {:error, _reason} = error ->
          [error | results]
      end
    end)
    |> Enum.reverse()
  end

  def run_automation(%Automation{} = automation, now \\ now()) do
    case claim_automation_occurrence(automation.id, "manual", now) do
      {:ok, execution, claimed_automation} ->
        execute_claimed_automation(claimed_automation, execution)

      {:skip, reason} ->
        {:error,
         %{"reason" => "automation_occurrence_not_claimed", "detail" => to_string(reason)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def claim_due_automation(automation_or_id, observed_at \\ now())

  def claim_due_automation(%Automation{id: automation_id}, observed_at) do
    claim_automation_occurrence(automation_id, "scheduled", observed_at)
  end

  def claim_due_automation(automation_id, observed_at) do
    claim_automation_occurrence(automation_id, "scheduled", observed_at)
  end

  defp claim_automation_occurrence(automation_id, trigger, observed_at) do
    Repo.transaction(fn ->
      automation = lock_automation!(automation_id)

      scheduled_for =
        case occurrence_time(automation, trigger, observed_at) do
          {:ok, scheduled_for} -> scheduled_for
          {:skip, reason} -> Repo.rollback({:skip, reason})
        end

      if occurrence_exists?(automation.id, scheduled_for) do
        Repo.rollback({:skip, :already_claimed})
      end

      if execution_in_flight?(automation.id) do
        Repo.rollback({:skip, :execution_in_flight})
      end

      next_scheduled_for =
        next_run_at(automation.cron_expression, scheduled_for, automation.timezone) ||
          Repo.rollback(%{
            "reason" => "automation_schedule_could_not_advance",
            "automation_id" => automation.id
          })

      execution =
        %AutomationExecution{}
        |> AutomationExecution.changeset(%{
          workspace_id: automation.workspace_id,
          automation_id: automation.id,
          trigger: trigger,
          status: "claimed",
          scheduled_for: scheduled_for,
          next_scheduled_for: next_scheduled_for,
          claimed_at: now(),
          metadata: %{
            "claim_policy" => "at_most_once",
            "observed_at" => DateTime.to_iso8601(observed_at)
          }
        })
        |> Repo.insert!()

      automation =
        automation
        |> Automation.changeset(%{"next_run_at" => next_scheduled_for})
        |> Repo.update!()

      %{execution: execution, automation: automation}
    end)
    |> case do
      {:ok, %{execution: execution, automation: automation}} ->
        {:ok, execution, Repo.preload(automation, [:agent])}

      {:error, {:skip, reason}} ->
        {:skip, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp occurrence_time(%Automation{} = automation, "scheduled", observed_at) do
    cond do
      automation.status != "active" ->
        {:skip, :inactive}

      is_nil(automation.next_run_at) ->
        {:skip, :not_scheduled}

      DateTime.compare(automation.next_run_at, observed_at) == :gt ->
        {:skip, :not_due}

      true ->
        {:ok, automation.next_run_at}
    end
  end

  defp occurrence_time(%Automation{}, "manual", observed_at), do: {:ok, observed_at}

  defp occurrence_exists?(automation_id, scheduled_for) do
    AutomationExecution
    |> where(
      [execution],
      execution.automation_id == ^automation_id and
        execution.scheduled_for == ^scheduled_for
    )
    |> Repo.exists?()
  end

  defp execution_in_flight?(automation_id) do
    AutomationExecution
    |> where(
      [execution],
      execution.automation_id == ^automation_id and
        execution.status in ^@in_flight_execution_statuses
    )
    |> Repo.exists?()
  end

  defp execute_claimed_automation(automation, execution) do
    with {:ok, execution} <- start_execution(execution) do
      case readiness(automation) do
        %{"status" => "blocked"} = readiness ->
          block_execution(automation, execution, readiness)

        _readiness ->
          create_and_execute_automation_run(automation, execution)
      end
    end
  end

  defp start_execution(%AutomationExecution{} = execution) do
    Repo.transaction(fn ->
      current = lock_execution!(execution.id)

      unless current.status == "claimed" do
        Repo.rollback(%{
          "reason" => "automation_execution_not_claimed",
          "status" => current.status
        })
      end

      current
      |> AutomationExecution.changeset(%{"status" => "running", "started_at" => now()})
      |> Repo.update!()
    end)
    |> transaction_result()
  end

  defp create_and_execute_automation_run(automation, execution) do
    case create_automation_run(automation, execution) do
      {:ok, run} ->
        case attach_execution_run(execution, run) do
          {:ok, execution} -> execute_automation_run(automation, execution, run)
          {:error, error} -> fail_automation_run(automation, execution, run, error)
        end

      {:error, error} ->
        fail_execution(automation, execution, nil, error)
    end
  end

  defp create_automation_run(automation, execution) do
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
        "automation_execution_id" => execution.id,
        "automation_trigger" => execution.trigger,
        "scheduled_for" => DateTime.to_iso8601(execution.scheduled_for)
      }
    })
  end

  defp attach_execution_run(execution, run) do
    Repo.transaction(fn ->
      current = lock_execution!(execution.id)

      unless current.status == "running" and is_nil(current.run_id) do
        Repo.rollback(%{
          "reason" => "automation_execution_run_not_attachable",
          "status" => current.status,
          "run_id" => current.run_id
        })
      end

      current
      |> AutomationExecution.changeset(%{"run_id" => run.id})
      |> Repo.update!()
    end)
    |> transaction_result()
  end

  defp execute_automation_run(automation, execution, run) do
    case Runtime.start_run(run) do
      {:ok, running_run} ->
        execute_started_automation_run(automation, execution, running_run)

      {:error, error} ->
        fail_automation_run(automation, execution, run, error)
    end
  end

  defp execute_started_automation_run(automation, execution, run) do
    with {:ok, conversation} <- start_automation_conversation(automation, run),
         {:ok, response} <-
           AgentChat.respond(conversation, automation.prompt, source: "automation") do
      complete_automation_run(automation, execution, run, response)
    else
      {:error, error} -> fail_automation_run(automation, execution, run, error)
    end
  end

  defp complete_automation_run(automation, execution, run, response) do
    run = Runtime.get_run!(run.id)

    case Runtime.complete_run(run, %{
           "result" => %{
             "conversation_id" => response.conversation.id,
             "assistant_turn_id" => response.assistant_turn.id
           },
           "metadata" =>
             Map.merge(run.metadata || %{}, %{
               "conversation_id" => response.conversation.id,
               "assistant_turn_id" => response.assistant_turn.id
             })
         }) do
      {:ok, _completed_run} ->
        complete_execution(automation, execution, run, response)

      {:error, error} ->
        fail_automation_run(automation, execution, run, error)
    end
  end

  defp complete_execution(automation, execution, run, response) do
    finished_at = now()

    finalize_execution(
      automation,
      execution,
      %{
        "status" => "completed",
        "finished_at" => finished_at,
        "result" => %{
          "run_id" => run.id,
          "conversation_id" => response.conversation.id,
          "assistant_turn_id" => response.assistant_turn.id
        },
        "last_error" => %{}
      },
      fn current_automation ->
        %{
          "last_run_at" => finished_at,
          "last_error" => %{},
          "metadata" =>
            Map.merge(current_automation.metadata || %{}, %{
              "last_execution_id" => execution.id,
              "last_run_id" => run.id,
              "last_conversation_id" => response.conversation.id,
              "last_assistant_turn_id" => response.assistant_turn.id
            })
        }
      end
    )
  end

  defp fail_automation_run(automation, execution, run, error) do
    normalized_error = normalize_error(error)
    run = Runtime.get_run!(run.id)

    _result = Runtime.fail_run(run, %{"result" => %{"error" => normalized_error}})

    fail_execution(automation, execution, run, normalized_error)
  end

  defp fail_execution(automation, execution, run, error) do
    finished_at = now()
    normalized_error = normalize_error(error)

    finalize_execution(
      automation,
      execution,
      %{
        "status" => "failed",
        "finished_at" => finished_at,
        "last_error" => normalized_error,
        "result" => if(run, do: %{"run_id" => run.id}, else: %{})
      },
      fn current_automation ->
        metadata =
          if run do
            Map.merge(current_automation.metadata || %{}, %{
              "last_execution_id" => execution.id,
              "last_run_id" => run.id
            })
          else
            Map.put(current_automation.metadata || %{}, "last_execution_id", execution.id)
          end

        %{
          "last_run_at" => finished_at,
          "last_error" => normalized_error,
          "metadata" => metadata
        }
      end
    )
  end

  defp block_execution(automation, execution, readiness) do
    finished_at = now()

    error = %{
      "reason" => "automation_connector_readiness_blocked",
      "message" => "Required connectors must be configured before this automation can run.",
      "readiness" => readiness
    }

    finalize_execution(
      automation,
      execution,
      %{
        "status" => "blocked",
        "finished_at" => finished_at,
        "last_error" => error,
        "result" => %{"executed" => false}
      },
      fn current_automation ->
        %{
          "last_run_at" => finished_at,
          "last_error" => error,
          "metadata" =>
            Map.put(current_automation.metadata || %{}, "last_execution_id", execution.id)
        }
      end
    )
  end

  defp finalize_execution(automation, execution, execution_attrs, automation_attrs) do
    Repo.transaction(fn ->
      current_automation = lock_automation!(automation.id)
      current_execution = lock_execution!(execution.id)

      unless current_execution.automation_id == current_automation.id and
               current_execution.status == "running" do
        Repo.rollback(%{
          "reason" => "automation_execution_not_running",
          "status" => current_execution.status
        })
      end

      current_execution
      |> AutomationExecution.changeset(execution_attrs)
      |> Repo.update!()

      current_automation
      |> Automation.changeset(automation_attrs.(current_automation))
      |> Repo.update!()
    end)
    |> transaction_result()
  end

  defp lock_automation!(id) do
    Automation
    |> where([automation], automation.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp lock_execution!(id) do
    AutomationExecution
    |> where([execution], execution.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

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
         scheduler_cursor <- DateTime.add(local_from, 1, :microsecond),
         {:ok, cron} <- Crontab.CronExpression.Parser.parse(expression),
         {:ok, naive} <-
           Crontab.Scheduler.get_next_run_date(cron, DateTime.to_naive(scheduler_cursor)),
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

  defp maybe_filter_execution_automation(query, nil), do: query

  defp maybe_filter_execution_automation(query, automation_id),
    do: where(query, [execution], execution.automation_id == ^automation_id)

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

  defp maybe_preload_agent(nil), do: nil
  defp maybe_preload_agent(automation), do: Repo.preload(automation, [:agent])

  defp normalize_id(value) when is_integer(value), do: value

  defp normalize_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _invalid -> -1
    end
  end

  defp normalize_id(_value), do: -1

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
