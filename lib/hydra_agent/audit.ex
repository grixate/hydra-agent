defmodule HydraAgent.Audit do
  @moduledoc """
  Workspace audit export.
  """

  import Ecto.Query

  alias HydraAgent.{
    Automations,
    Budgets,
    Evals,
    Gateways,
    MCP,
    Providers,
    Repo,
    Runtime,
    Safety
  }

  alias HydraAgent.Runtime.RunEvent
  alias HydraAgent.Tools.{Bundles, Registry}

  def export_workspace(workspace_id) do
    workspace = Runtime.get_workspace!(workspace_id)

    %{
      "workspace" => %{
        "id" => workspace.id,
        "name" => workspace.name,
        "slug" => workspace.slug,
        "status" => workspace.status
      },
      "exported_at" =>
        DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "agents" => Enum.map(Runtime.list_agents(workspace_id), &agent_json/1),
      "providers" => Enum.map(Providers.list_configs(workspace_id), &provider_json/1),
      "budgets" => Enum.map(Budgets.list_budgets(workspace_id), &budget_json/1),
      "tool_policies" => Enum.map(Runtime.list_tool_policies(workspace_id), &policy_json/1),
      "tools" => Registry.all(),
      "tool_bundles" => Bundles.all(),
      "mcp_servers" => Enum.map(MCP.list_servers(workspace_id), &mcp_server_json/1),
      "runs" => Enum.map(Runtime.list_runs(workspace_id), &run_json/1),
      "run_events" => Enum.map(run_events(workspace_id), &run_event_json/1),
      "safety_events" =>
        Enum.map(Safety.list_events(workspace_id, limit: 1000), &safety_event_json/1),
      "automations" => Enum.map(Automations.list_automations(workspace_id), &automation_json/1),
      "webhooks" => Enum.map(Gateways.list_webhooks(workspace_id), &webhook_json/1),
      "eval_suites" => Enum.map(Evals.list_suites(workspace_id), &suite_json/1)
    }
  end

  defp run_events(workspace_id) do
    RunEvent
    |> where([event], event.workspace_id == ^workspace_id)
    |> order_by([event], asc: event.inserted_at)
    |> limit(1000)
    |> Repo.all()
  end

  defp agent_json(agent) do
    %{
      "id" => agent.id,
      "slug" => agent.slug,
      "name" => agent.name,
      "role" => agent.role,
      "status" => agent.status,
      "model_route" => agent.model_route,
      "capability_profile" => agent.capability_profile
    }
  end

  defp provider_json(provider) do
    %{
      "id" => provider.id,
      "name" => provider.name,
      "kind" => provider.kind,
      "model" => provider.model,
      "api_key_ref" => HydraAgent.Secrets.safe_ref(provider.api_key_env),
      "enabled" => provider.enabled,
      "metadata" => provider.metadata
    }
  end

  defp budget_json(budget) do
    %{
      "id" => budget.id,
      "agent_id" => budget.agent_id,
      "name" => budget.name,
      "status" => budget.status,
      "category" => budget.category,
      "period" => budget.period,
      "token_limit" => budget.token_limit,
      "cost_limit" => if(budget.cost_limit, do: Decimal.to_string(budget.cost_limit), else: nil),
      "metadata" => budget.metadata
    }
  end

  defp policy_json(policy) do
    %{
      "id" => policy.id,
      "agent_id" => policy.agent_id,
      "scope" => policy.scope,
      "allowed_tools" => policy.allowed_tools,
      "side_effect_classes" => policy.side_effect_classes,
      "network_allowlist" => policy.network_allowlist,
      "shell_allowlist" => policy.shell_allowlist,
      "shell_env_allowlist" => Map.get(policy, :shell_env_allowlist, []),
      "filesystem_allowlist" => Map.get(policy, :filesystem_allowlist, []),
      "filesystem_denylist" => Map.get(policy, :filesystem_denylist, []),
      "tool_bundles" => get_in(policy.metadata || %{}, ["tool_bundles"]) || [],
      "requires_approval" => policy.requires_approval
    }
  end

  defp mcp_server_json(server) do
    %{
      "id" => server.id,
      "slug" => server.slug,
      "name" => server.name,
      "status" => server.status,
      "transport" => server.transport,
      "trust_level" => server.trust_level,
      "env_refs" => server.env_refs,
      "include_tools" => server.include_tools,
      "exclude_tools" => server.exclude_tools,
      "resource_access" => server.resource_access,
      "prompt_access" => server.prompt_access,
      "timeout_ms" => server.timeout_ms,
      "approval_sensitive" => server.approval_sensitive,
      "health_status" => server.health_status,
      "last_checked_at" => server.last_checked_at,
      "last_error" => server.last_error,
      "metadata" => server.metadata
    }
  end

  defp run_json(run) do
    %{
      "id" => run.id,
      "title" => run.title,
      "goal" => run.goal,
      "status" => run.status,
      "autonomy_level" => run.autonomy_level,
      "supervisor_agent_id" => run.supervisor_agent_id,
      "steps" => Enum.map(loaded(run.steps), &step_json/1)
    }
  end

  defp step_json(step) do
    %{
      "id" => step.id,
      "index" => step.index,
      "title" => step.title,
      "status" => step.status,
      "tool_name" => step.tool_name,
      "side_effect_class" => step.side_effect_class,
      "attempt_count" => Map.get(step, :attempt_count)
    }
  end

  defp run_event_json(event) do
    %{
      "id" => event.id,
      "run_id" => event.run_id,
      "run_step_id" => event.run_step_id,
      "agent_id" => event.agent_id,
      "event_type" => event.event_type,
      "summary" => event.summary,
      "payload" => event.payload,
      "inserted_at" => event.inserted_at
    }
  end

  defp safety_event_json(event) do
    %{
      "id" => event.id,
      "agent_id" => event.agent_id,
      "run_id" => event.run_id,
      "run_step_id" => event.run_step_id,
      "category" => event.category,
      "severity" => event.severity,
      "action" => event.action,
      "summary" => event.summary,
      "metadata" => event.metadata,
      "inserted_at" => event.inserted_at
    }
  end

  defp automation_json(automation) do
    %{
      "id" => automation.id,
      "agent_id" => automation.agent_id,
      "slug" => automation.slug,
      "name" => automation.name,
      "status" => automation.status,
      "cron_expression" => automation.cron_expression,
      "next_run_at" => automation.next_run_at,
      "last_run_at" => automation.last_run_at,
      "last_error" => automation.last_error
    }
  end

  defp webhook_json(webhook) do
    %{
      "id" => webhook.id,
      "agent_id" => webhook.agent_id,
      "slug" => webhook.slug,
      "name" => webhook.name,
      "status" => webhook.status,
      "target_type" => webhook.target_type,
      "token_ref" => HydraAgent.Secrets.safe_ref(webhook.token_env),
      "last_received_at" => webhook.last_received_at,
      "last_error" => webhook.last_error
    }
  end

  defp suite_json(suite) do
    %{
      "id" => suite.id,
      "slug" => suite.slug,
      "name" => suite.name,
      "status" => suite.status
    }
  end

  defp loaded(value), do: if(Ecto.assoc_loaded?(value), do: value, else: [])
end
