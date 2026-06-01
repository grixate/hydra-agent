defmodule HydraAgentWeb.McpController do
  use HydraAgentWeb, :controller

  alias HydraAgent.MCP

  def index(conn, %{"workspace_id" => workspace_id}) do
    servers = MCP.list_servers(workspace_id)
    json(conn, %{data: Enum.map(servers, &server_json/1)})
  end

  def show(conn, %{"id" => id}) do
    server = MCP.get_server!(id)
    json(conn, %{data: server_json(server)})
  end

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    create_server(conn, Map.put(params, "workspace_id", workspace_id))
  end

  def create(conn, params), do: create_server(conn, params)

  def update(conn, %{"id" => id} = params) do
    server = MCP.get_server!(id)

    case MCP.update_server(server, params) do
      {:ok, updated_server} ->
        json(conn, %{data: server_json(updated_server)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  defp create_server(conn, params) do
    case MCP.create_server(params) do
      {:ok, server} ->
        conn
        |> put_status(:created)
        |> json(%{data: server_json(server)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(changeset)})
    end
  end

  defp server_json(server) do
    %{
      id: server.id,
      workspace_id: server.workspace_id,
      name: server.name,
      slug: server.slug,
      status: server.status,
      transport: server.transport,
      trust_level: server.trust_level,
      config: server.config,
      env_refs: server.env_refs,
      include_tools: server.include_tools,
      exclude_tools: server.exclude_tools,
      resource_access: server.resource_access,
      prompt_access: server.prompt_access,
      timeout_ms: server.timeout_ms,
      approval_sensitive: server.approval_sensitive,
      health_status: server.health_status,
      last_checked_at: server.last_checked_at,
      last_error: server.last_error,
      metadata: server.metadata
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
