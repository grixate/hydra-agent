defmodule HydraAgent.Automations do
  @moduledoc """
  Workspace-scoped scheduled automations.

  Automations send prompts to an agent on a cron schedule and persist the
  resulting conversation turns through the normal agent chat path.
  """

  import Ecto.Query

  alias HydraAgent.AgentChat
  alias HydraAgent.Automations.Automation
  alias HydraAgent.Repo

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
        next_run_at(attrs["cron_expression"] || attrs[:cron_expression])
      )

    %Automation{} |> Automation.changeset(attrs) |> Repo.insert()
  end

  def update_automation(%Automation{} = automation, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> maybe_refresh_next_run_at()

    automation |> Automation.changeset(attrs) |> Repo.update()
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

    with {:ok, conversation} <-
           AgentChat.start_conversation(automation.agent, %{
             title: "Automation: #{automation.name}",
             channel: "automation",
             metadata: %{"automation_id" => automation.id}
           }),
         {:ok, response} <-
           AgentChat.respond(conversation, automation.prompt, source: "automation") do
      update_automation(automation, %{
        "last_run_at" => now,
        "next_run_at" => next_run_at(automation.cron_expression, now),
        "last_error" => %{},
        "metadata" =>
          Map.merge(automation.metadata || %{}, %{
            "last_conversation_id" => response.conversation.id,
            "last_assistant_turn_id" => response.assistant_turn.id
          })
      })
    else
      {:error, error} ->
        update_automation(automation, %{
          "last_run_at" => now,
          "next_run_at" => next_run_at(automation.cron_expression, now),
          "last_error" => normalize_error(error)
        })
    end
  end

  def next_run_at(expression, from \\ now())

  def next_run_at(nil, _from), do: nil

  def next_run_at(expression, from) when is_binary(expression) do
    with {:ok, cron} <- Crontab.CronExpression.Parser.parse(expression),
         {:ok, naive} <- Crontab.Scheduler.get_next_run_date(cron, DateTime.to_naive(from)) do
      DateTime.from_naive!(naive, "Etc/UTC")
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
    Map.put_new(attrs, "next_run_at", next_run_at(expression))
  end

  defp maybe_refresh_next_run_at(attrs), do: attrs

  defp normalize_error(%Ecto.Changeset{} = changeset) do
    %{"reason" => "changeset_error", "errors" => changeset_errors(changeset)}
  end

  defp normalize_error(error) when is_map(error), do: error
  defp normalize_error(error), do: %{"reason" => inspect(error)}

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
