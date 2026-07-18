defmodule HydraAgentWeb.Plugs.RequireOperatorAuthority do
  @moduledoc """
  Reserves deployment-affecting API actions for the break-glass operator token.

  Workspace database tokens intentionally remain suitable for ordinary scoped
  data mutations, but cannot configure secret consumers, grant execution
  authority, execute dangerous work, or approve it. Local development keeps
  its auth-disabled workflow.
  """

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      not api_auth_enabled?() ->
        conn

      environment_principal?(conn.assigns[:api_principal]) ->
        conn

      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{errors: %{"reason" => "operator_authority_required"}})
        |> halt()
    end
  end

  defp api_auth_enabled? do
    :hydra_agent
    |> Application.get_env(:api_auth, [])
    |> Keyword.get(:enabled?, false)
  end

  defp environment_principal?(%{type: :environment_token}), do: true
  defp environment_principal?(%{"type" => "environment_token"}), do: true
  defp environment_principal?(_principal), do: false
end
