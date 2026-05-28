defmodule HydraAgentWeb.Plugs.ApiAuth do
  @moduledoc """
  Optional env-backed bearer authentication for JSON APIs.

  Local development remains open by default. Deployments can enable this plug
  through `config :hydra_agent, :api_auth, enabled?: true, token_env: "..."`.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias HydraAgent.Secrets

  def init(opts), do: opts

  def call(conn, _opts) do
    config = Application.get_env(:hydra_agent, :api_auth, [])

    if Keyword.get(config, :enabled?, false) do
      verify(conn, Keyword.get(config, :token_env))
    else
      conn
    end
  end

  defp verify(conn, token_env) when is_binary(token_env) and token_env != "" do
    case Secrets.verify_bearer(conn, token_env) do
      :ok ->
        conn

      {:error, %{"reason" => "missing_secret_env"} = error} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{errors: error})
        |> halt()

      {:error, error} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{errors: error})
        |> halt()
    end
  end

  defp verify(conn, _token_env) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{errors: %{"reason" => "missing_api_auth_token_env"}})
    |> halt()
  end
end
