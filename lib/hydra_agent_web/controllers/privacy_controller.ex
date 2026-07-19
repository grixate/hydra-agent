defmodule HydraAgentWeb.PrivacyController do
  use HydraAgentWeb, :controller

  alias HydraAgent.{Accounts, PublicDisclosure, Runtime}
  alias HydraAgentWeb.PrivacyCopy

  def show(conn, params) do
    locale = PrivacyCopy.locale(params["locale"])
    workspaces = Accounts.list_research_workspaces(conn.assigns[:current_user])
    workspace = selected_workspace(workspaces, params["workspace_id"])

    providers =
      case workspace do
        nil -> []
        workspace -> workspace.id |> Runtime.list_providers() |> provider_disclosures()
      end

    render(conn, :show,
      page_title: PrivacyCopy.t(locale, :page_title),
      locale: locale,
      workspaces: workspaces,
      workspace: workspace,
      providers: providers,
      disclosure: PublicDisclosure.snapshot(),
      operations_authorized?: Accounts.operations_authorized?(conn.assigns[:current_user])
    )
  end

  defp selected_workspace([], _id), do: nil
  defp selected_workspace(workspaces, nil), do: List.first(workspaces)

  defp selected_workspace(workspaces, id) do
    case Integer.parse(to_string(id)) do
      {parsed, ""} -> Enum.find(workspaces, List.first(workspaces), &(&1.id == parsed))
      _invalid -> List.first(workspaces)
    end
  end

  defp provider_disclosures(providers) do
    providers
    |> Enum.filter(& &1.enabled)
    |> Enum.map(fn provider ->
      %{
        name: provider.name,
        model: provider.model,
        kind: provider.kind,
        posture: provider_posture(provider.kind)
      }
    end)
    |> Enum.sort_by(&{posture_order(&1.posture), String.downcase(&1.name)})
  end

  defp provider_posture("mock"), do: :test_only
  defp provider_posture("ollama"), do: :local
  defp provider_posture(_kind), do: :external

  defp posture_order(:local), do: 0
  defp posture_order(:external), do: 1
  defp posture_order(:test_only), do: 2
end
