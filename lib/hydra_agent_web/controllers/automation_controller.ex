defmodule HydraAgentWeb.AutomationController do
  use HydraAgentWeb, :controller

  alias HydraAgent.{Automations, Connectors}

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    automations = Automations.list_automations(workspace_id, status: params["status"])
    connector_accounts = Connectors.list_accounts(workspace_id)
    json(conn, %{data: Enum.map(automations, &automation_json(&1, connector_accounts))})
  end

  def recipes(conn, _params) do
    json(conn, %{data: Automations.recipes()})
  end

  def create_from_recipe(
        conn,
        %{"workspace_id" => workspace_id, "recipe_id" => recipe_id} = params
      ) do
    case Automations.create_from_recipe(workspace_id, recipe_id, params) do
      {:ok, automation} ->
        conn |> put_status(:created) |> json(%{data: automation_json(automation)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
    end
  end

  def show(conn, %{"id" => id}) do
    automation = Automations.get_automation!(id)
    json(conn, %{data: automation_json(automation)})
  end

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    create_automation(conn, Map.put(params, "workspace_id", workspace_id))
  end

  def create(conn, params) do
    create_automation(conn, params)
  end

  def update(conn, %{"id" => id} = params) do
    automation = Automations.get_automation!(id)

    case Automations.update_automation(automation, params) do
      {:ok, automation} ->
        json(conn, %{data: automation_json(automation)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  def run(conn, %{"id" => id}) do
    automation = Automations.get_automation!(id)

    case Automations.run_automation(automation) do
      {:ok, automation} ->
        json(conn, %{data: automation_json(automation)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  defp create_automation(conn, params) do
    case Automations.create_automation(params) do
      {:ok, automation} ->
        conn
        |> put_status(:created)
        |> json(%{data: automation_json(automation)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  defp automation_json(automation, connector_accounts \\ nil) do
    readiness =
      if is_nil(connector_accounts) do
        Automations.readiness(automation)
      else
        Automations.readiness(automation, connector_accounts)
      end

    %{
      id: automation.id,
      workspace_id: automation.workspace_id,
      agent_id: automation.agent_id,
      name: automation.name,
      slug: automation.slug,
      status: automation.status,
      cron_expression: automation.cron_expression,
      timezone: automation.timezone,
      prompt: automation.prompt,
      last_run_at: automation.last_run_at,
      next_run_at: automation.next_run_at,
      last_error: automation.last_error,
      readiness: readiness,
      metadata: automation.metadata
    }
  end

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
