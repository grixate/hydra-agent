defmodule HydraAgentWeb.Plugs.ApiAuth do
  @moduledoc "Fail-closed environment or database-backed API authentication."

  import Plug.Conn
  import Phoenix.Controller

  alias HydraAgent.{ApiCredentials, Secrets}

  def init(opts), do: opts

  def call(conn, _opts) do
    config = Application.get_env(:hydra_agent, :api_auth, [])

    if Keyword.get(config, :enabled?, false) do
      authenticate(conn, Keyword.get(config, :token_env))
    else
      conn
    end
  end

  defp authenticate(conn, token_env) when is_binary(token_env) and token_env != "" do
    with {:ok, raw_token} <- bearer_token(conn) do
      case Secrets.verify_bearer(conn, token_env) do
        :ok ->
          assign(conn, :api_principal, %{
            type: :environment_token,
            workspace_id: nil,
            permissions: ["read", "write"]
          })

        {:error, %{"reason" => "missing_secret_env"} = error} ->
          reject(conn, :service_unavailable, error)

        {:error, _error} ->
          authenticate_database_token(conn, raw_token)
      end
    else
      {:error, error} -> reject(conn, :unauthorized, error)
    end
  end

  defp authenticate(conn, _token_env) do
    reject(conn, :service_unavailable, %{"reason" => "missing_api_auth_token_env"})
  end

  defp authenticate_database_token(conn, raw_token) do
    workspace_id = request_workspace_id(conn)

    case ApiCredentials.authenticate(raw_token, conn.method, workspace_id) do
      {:ok, principal} ->
        assign(conn, :api_principal, principal)

      {:error, :workspace_scope_required} ->
        reject(conn, :forbidden, %{"reason" => "workspace_scope_required"})

      {:error, :workspace_scope_mismatch} ->
        reject(conn, :forbidden, %{"reason" => "workspace_scope_mismatch"})

      {:error, :insufficient_permission} ->
        reject(conn, :forbidden, %{"reason" => "insufficient_permission"})

      {:error, _reason} ->
        reject(conn, :unauthorized, %{"reason" => "invalid_bearer_token"})
    end
  end

  defp request_workspace_id(conn) do
    conn.path_params["workspace_id"] || workspace_show_id(conn)
  end

  defp workspace_show_id(%{
         method: method,
         path_info: ["api", "v1", "workspaces", id]
       })
       when method in ["GET", "HEAD"],
       do: id

  defp workspace_show_id(_conn), do: nil

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      [] -> {:error, %{"reason" => "missing_bearer_token"}}
      _ -> {:error, %{"reason" => "invalid_authorization_header"}}
    end
  end

  defp reject(conn, status, error) do
    conn
    |> put_status(status)
    |> json(%{errors: error})
    |> halt()
  end
end
