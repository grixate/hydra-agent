defmodule HydraAgent.MCP do
  @moduledoc """
  MCP server registry.

  This module stores configuration only. It does not execute MCP tools; runtime
  execution must still go through explicit tool registration, policy grants,
  approvals, and audit events.
  """

  import Ecto.Query

  alias HydraAgent.MCP.Server
  alias HydraAgent.Repo
  alias HydraAgent.{Redaction, Runtime, Secrets}

  def list_servers(workspace_id) do
    Server
    |> where([server], server.workspace_id == ^workspace_id)
    |> order_by([server], asc: server.name)
    |> Repo.all()
  end

  def get_server!(id), do: Repo.get!(Server, id)

  def get_server_for_workspace!(workspace_id, id) do
    id = normalize_id(id)

    Server
    |> where([server], server.workspace_id == ^workspace_id and server.id == ^id)
    |> Repo.one!()
  end

  def get_server_by_slug(workspace_id, slug) when is_binary(slug) do
    Server
    |> where([server], server.workspace_id == ^workspace_id and server.slug == ^slug)
    |> Repo.one()
  end

  def create_server(attrs) do
    %Server{}
    |> Server.changeset(attrs)
    |> Repo.insert()
  end

  def update_server(%Server{} = server, attrs) do
    server
    |> Server.changeset(attrs)
    |> Repo.update()
  end

  def stop_stdio_session(%Server{} = server), do: stop_stdio_session(server.id)

  def stop_stdio_session(server_id) do
    HydraAgent.MCP.StdioSession.stop(normalize_id(server_id))
  end

  def stdio_session_status(%Server{} = server), do: stdio_session_status(server.id)

  def stdio_session_status(server_id) do
    HydraAgent.MCP.StdioSession.status(normalize_id(server_id))
  end

  def discover_server(server_or_id, context \\ %{}, opts \\ [])

  def discover_server(%Server{} = server, context, opts) do
    checked_at = now()

    case discover_transport(server, stringify_keys(context || %{}), opts) do
      {:ok, discovery} ->
        update_server(server, %{
          health_status: "healthy",
          last_checked_at: checked_at,
          last_error: %{},
          metadata:
            Map.merge(server.metadata || %{}, %{
              "discovery" => discovery,
              "discovered_at" => DateTime.to_iso8601(checked_at)
            })
        })

      {:error, error} ->
        redacted_error = Redaction.redact(error)

        with {:ok, updated} <-
               update_server(server, %{
                 health_status: "unhealthy",
                 last_checked_at: checked_at,
                 last_error: redacted_error
               }) do
          {:error, Map.put(redacted_error, "server_id", updated.id)}
        end
    end
  end

  def discover_server(server_id, context, opts) do
    workspace_id = context["workspace_id"] || context[:workspace_id]
    server = get_server_for_workspace!(workspace_id, server_id)
    discover_server(server, context, opts)
  end

  def authorize_call(workspace_id, input) do
    input = stringify_keys(input || %{})

    with {:ok, server} <- resolve_server(workspace_id, input),
         :ok <- active_server(server),
         {:ok, tool_name} <- tool_name(input),
         :ok <- tool_filter_allowed(server, tool_name) do
      :ok
    else
      {:blocked, reason, metadata} -> {:blocked, reason, metadata}
    end
  end

  def execute_tool(server_or_id, tool_name, params, context \\ %{}, opts \\ [])

  def execute_tool(%Server{} = server, tool_name, params, context, opts) do
    context = stringify_keys(context || %{})
    params = stringify_keys(params || %{})

    with :ok <- active_server(server),
         :ok <- tool_filter_allowed(server, tool_name),
         :ok <- record_call_event(server, tool_name, params, context, "mcp.call.started"),
         {:ok, result} <- call_transport(server, tool_name, params, context, opts),
         :ok <- record_call_event(server, tool_name, result, context, "mcp.call.completed") do
      {:ok,
       %{
         "server_id" => server.id,
         "server_slug" => server.slug,
         "tool_name" => tool_name,
         "result" => result
       }}
    else
      {:error, error} ->
        record_call_event(server, tool_name, error, context, "mcp.call.failed")
        {:error, error}

      {:blocked, reason, metadata} ->
        error = %{"reason" => reason, "metadata" => metadata}
        record_call_event(server, tool_name, error, context, "mcp.call.failed")
        {:error, error}
    end
  end

  def execute_tool(server_id, tool_name, params, context, opts) do
    workspace_id = context["workspace_id"] || context[:workspace_id]
    server = get_server_for_workspace!(workspace_id, server_id)
    execute_tool(server, tool_name, params, context, opts)
  end

  def resolve_server(workspace_id, input) do
    input = stringify_keys(input || %{})

    cond do
      input["server_id"] ->
        {:ok, get_server_for_workspace!(workspace_id, input["server_id"])}

      input["server_slug"] ->
        case get_server_by_slug(workspace_id, input["server_slug"]) do
          nil -> {:blocked, "mcp_server_not_found", %{"server_slug" => input["server_slug"]}}
          server -> {:ok, server}
        end

      true ->
        {:blocked, "mcp_server_required", %{}}
    end
  rescue
    Ecto.NoResultsError ->
      {:blocked, "mcp_server_not_found", %{"server_id" => input["server_id"]}}
  end

  defp active_server(%Server{status: "active"}), do: :ok

  defp active_server(%Server{} = server) do
    {:blocked, "mcp_server_not_active", %{"server_id" => server.id, "status" => server.status}}
  end

  defp tool_name(%{"tool_name" => tool_name}) when is_binary(tool_name) and tool_name != "",
    do: {:ok, tool_name}

  defp tool_name(_input), do: {:blocked, "mcp_tool_name_required", %{}}

  defp tool_filter_allowed(%Server{} = server, tool_name) do
    cond do
      tool_name in (server.exclude_tools || []) ->
        {:blocked, "mcp_tool_excluded",
         %{"tool_name" => tool_name, "exclude_tools" => server.exclude_tools}}

      server.include_tools == [] ->
        {:blocked, "mcp_tool_not_included", %{"tool_name" => tool_name, "include_tools" => []}}

      tool_name in server.include_tools ->
        :ok

      true ->
        {:blocked, "mcp_tool_not_included",
         %{"tool_name" => tool_name, "include_tools" => server.include_tools}}
    end
  end

  defp call_transport(%Server{transport: "http"} = server, tool_name, params, _context, opts) do
    call_json_rpc(
      server,
      "tools/call",
      %{"name" => tool_name, "arguments" => params},
      %{},
      opts
    )
  end

  defp call_transport(%Server{transport: "stdio"} = server, tool_name, params, context, opts) do
    call_json_rpc(
      server,
      "tools/call",
      %{"name" => tool_name, "arguments" => params},
      context,
      opts
    )
  end

  defp call_transport(%Server{transport: "sse"} = server, tool_name, params, context, opts) do
    call_json_rpc(
      server,
      "tools/call",
      %{"name" => tool_name, "arguments" => params},
      context,
      opts
    )
  end

  defp call_transport(%Server{} = server, _tool_name, _params, _context, _opts) do
    {:error, %{"reason" => "mcp_transport_not_executable", "transport" => server.transport}}
  end

  defp discover_transport(%Server{} = server, context, opts) do
    with {:ok, tools} <- call_json_rpc(server, "tools/list", %{}, context, opts),
         {:ok, resources} <- maybe_discover_resources(server, context, opts),
         {:ok, prompts} <- maybe_discover_prompts(server, context, opts) do
      {:ok,
       %{
         "tools" => Map.get(to_map(tools), "tools", []),
         "resources" => Map.get(to_map(resources), "resources", []),
         "prompts" => Map.get(to_map(prompts), "prompts", [])
       }}
    end
  end

  defp maybe_discover_resources(%Server{resource_access: true} = server, context, opts) do
    call_json_rpc(server, "resources/list", %{}, context, opts)
  end

  defp maybe_discover_resources(_server, _context, _opts), do: {:ok, %{"resources" => []}}

  defp maybe_discover_prompts(%Server{prompt_access: true} = server, context, opts) do
    call_json_rpc(server, "prompts/list", %{}, context, opts)
  end

  defp maybe_discover_prompts(_server, _context, _opts), do: {:ok, %{"prompts" => []}}

  defp call_json_rpc(%Server{transport: "http"} = server, method, params, _context, opts) do
    body = json_rpc_body(method, params)

    req_opts =
      [
        method: :post,
        url: server.config["url"],
        json: body,
        headers: auth_headers(server),
        receive_timeout: server.timeout_ms
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.request(req_opts) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        response_body
        |> decode_body()
        |> decode_json_rpc_response()

      {:ok, %{status: status, body: response_body}} ->
        {:error,
         %{
           "reason" => "mcp_http_error",
           "status" => status,
           "body" => response_body |> decode_body() |> Redaction.redact()
         }}

      {:error, error} ->
        {:error, %{"reason" => "mcp_request_failed", "error" => Exception.message(error)}}
    end
  end

  defp call_json_rpc(%Server{transport: "sse"} = server, method, params, _context, opts) do
    body = json_rpc_body(method, params)

    req_opts =
      [
        method: :post,
        url: server.config["url"],
        json: body,
        headers: [{"accept", "text/event-stream"} | auth_headers(server)],
        receive_timeout: server.timeout_ms
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.request(req_opts) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        response_body
        |> decode_sse_json_rpc_body()
        |> decode_json_rpc_response()

      {:ok, %{status: status, body: response_body}} ->
        {:error,
         %{
           "reason" => "mcp_sse_http_error",
           "status" => status,
           "body" => response_body |> decode_body() |> Redaction.redact()
         }}

      {:error, error} ->
        {:error, %{"reason" => "mcp_sse_request_failed", "error" => Exception.message(error)}}
    end
  end

  defp call_json_rpc(%Server{transport: "stdio"} = server, method, params, context, _opts) do
    with {:ok, {program, args}} <- stdio_command(server),
         {:ok, executable} <- executable_path(program),
         {:ok, cwd} <- stdio_cwd(server, context),
         {:ok, env} <- stdio_env(server),
         {:ok, request} <- encode_stdio_request(method, params),
         {:ok, response} <-
           call_stdio_transport(server, executable, args, cwd, env, request, server.timeout_ms) do
      response
      |> decode_body()
      |> decode_json_rpc_response()
    end
  end

  defp call_json_rpc(%Server{} = server, _method, _params, _context, _opts) do
    {:error, %{"reason" => "mcp_transport_not_executable", "transport" => server.transport}}
  end

  defp json_rpc_body(method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }
  end

  defp stdio_command(%Server{} = server) do
    case server.config["command"] do
      [program | args] when is_binary(program) ->
        {:ok, {program, args}}

      _command ->
        {:error, %{"reason" => "mcp_stdio_command_invalid"}}
    end
  end

  defp executable_path(program) do
    cond do
      Path.type(program) == :absolute and File.exists?(program) ->
        {:ok, program}

      executable = System.find_executable(program) ->
        {:ok, executable}

      true ->
        {:error, %{"reason" => "mcp_stdio_executable_not_found", "program" => program}}
    end
  end

  defp stdio_cwd(%Server{} = server, context) do
    root = Path.expand(context["workspace_root"] || File.cwd!())
    configured = server.config["cwd"]
    cwd = Path.expand(configured || root)

    cond do
      not is_nil(configured) and not is_binary(configured) ->
        {:error, %{"reason" => "mcp_stdio_cwd_invalid"}}

      cwd == root or String.starts_with?(cwd, root <> "/") ->
        {:ok, cwd}

      true ->
        {:error,
         %{
           "reason" => "mcp_stdio_cwd_outside_workspace_root",
           "cwd" => cwd,
           "workspace_root" => root
         }}
    end
  end

  defp stdio_env(%Server{} = server) do
    server.env_refs
    |> Enum.reduce_while({:ok, []}, fn env_ref, {:ok, acc} ->
      case Secrets.fetch_env(env_ref) do
        {:ok, value} ->
          {:cont, {:ok, [{String.to_charlist(env_ref), String.to_charlist(value)} | acc]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, error} -> {:error, error}
    end
  end

  defp encode_stdio_request(method, params) do
    case Jason.encode(json_rpc_body(method, params)) do
      {:ok, json} ->
        {:ok, json <> "\n"}

      {:error, error} ->
        {:error, %{"reason" => "mcp_stdio_encode_failed", "error" => inspect(error)}}
    end
  end

  defp call_stdio(executable, args, cwd, env, request, timeout_ms) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:args, args},
        {:cd, cwd},
        {:env, env}
      ])

    Port.command(port, request)
    collect_stdio(port, "", timeout_ms)
  rescue
    error ->
      {:error, %{"reason" => "mcp_stdio_failed", "error" => Exception.message(error)}}
  end

  defp call_stdio_transport(server, executable, args, cwd, env, request, timeout_ms) do
    if server.config["persistent"] == true do
      HydraAgent.MCP.StdioSession.call(
        server.id,
        executable,
        args,
        cwd,
        env,
        request,
        timeout_ms,
        server.config["idle_timeout_ms"] || 300_000
      )
    else
      call_stdio(executable, args, cwd, env, request, timeout_ms)
    end
  end

  defp collect_stdio(port, buffer, timeout_ms) do
    case stdio_json_line(buffer) do
      {:ok, line} ->
        close_port(port)
        {:ok, line}

      :more ->
        receive do
          {^port, {:data, chunk}} ->
            collect_stdio(port, buffer <> chunk, timeout_ms)

          {^port, {:exit_status, status}} ->
            close_port(port)
            stdio_exit_result(buffer, status)
        after
          timeout_ms ->
            close_port(port)
            {:error, %{"reason" => "mcp_stdio_timeout", "timeout_ms" => timeout_ms}}
        end
    end
  end

  defp stdio_json_line(buffer) do
    buffer
    |> String.split("\n")
    |> Enum.find_value(:more, fn line ->
      line = String.trim(line)

      cond do
        line == "" ->
          false

        match?({:ok, %{}}, Jason.decode(line)) ->
          {:ok, line}

        true ->
          false
      end
    end)
  end

  defp stdio_exit_result(buffer, 0) do
    case stdio_json_line(buffer) do
      {:ok, line} -> {:ok, line}
      :more -> {:error, %{"reason" => "mcp_stdio_empty_response"}}
    end
  end

  defp stdio_exit_result(buffer, status) do
    {:error,
     %{
       "reason" => "mcp_stdio_exit",
       "exit_status" => status,
       "output" => Redaction.redact(String.trim(buffer))
     }}
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    _error -> :ok
  end

  defp decode_json_rpc_response(%{"error" => error}) do
    {:error, %{"reason" => "mcp_json_rpc_error", "error" => Redaction.redact(error)}}
  end

  defp decode_json_rpc_response(%{"result" => result}), do: {:ok, result}

  defp decode_json_rpc_response(body) do
    {:error, %{"reason" => "mcp_invalid_json_rpc_response", "body" => Redaction.redact(body)}}
  end

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _error} -> body
    end
  end

  defp decode_body(body), do: body

  defp decode_sse_json_rpc_body(body) when is_binary(body) do
    body
    |> String.split("\n\n")
    |> Enum.find_value(%{"error" => %{"reason" => "mcp_sse_empty_response"}}, fn event ->
      data =
        event
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map(fn "data:" <> value -> String.trim(value) end)
        |> Enum.reject(&(&1 == "" or &1 == "[DONE]"))
        |> Enum.join("\n")

      cond do
        data == "" ->
          false

        match?({:ok, %{}}, Jason.decode(data)) ->
          {:ok, decoded} = Jason.decode(data)
          decoded

        true ->
          %{"error" => %{"reason" => "mcp_sse_invalid_json", "data" => Redaction.redact(data)}}
      end
    end)
  end

  defp decode_sse_json_rpc_body(body), do: body

  defp auth_headers(%Server{} = server) do
    bearer_env = server.config["bearer_env"]

    cond do
      is_binary(bearer_env) and bearer_env in (server.env_refs || []) ->
        case Secrets.fetch_env(bearer_env) do
          {:ok, token} -> [{"authorization", "Bearer #{token}"}]
          {:error, _error} -> []
        end

      true ->
        []
    end
  end

  defp record_call_event(server, tool_name, payload, context, event_type) do
    case {context["workspace_id"], context["run_id"]} do
      {workspace_id, run_id} when not is_nil(workspace_id) and not is_nil(run_id) ->
        Runtime.record_run_event(%{
          workspace_id: workspace_id,
          run_id: run_id,
          run_step_id: context["run_step_id"],
          agent_id: context["agent_id"],
          event_type: event_type,
          summary: summary(event_type),
          payload: %{
            "server_id" => server.id,
            "server_slug" => server.slug,
            "mcp_tool_name" => tool_name,
            "payload" => Redaction.redact(payload)
          }
        })
        |> case do
          {:ok, _event} ->
            :ok

          {:error, changeset} ->
            {:error,
             %{"reason" => "mcp_audit_event_failed", "errors" => inspect(changeset.errors)}}
        end

      _missing_run_context ->
        :ok
    end
  end

  defp summary("mcp.call.started"), do: "MCP call started"
  defp summary("mcp.call.completed"), do: "MCP call completed"
  defp summary("mcp.call.failed"), do: "MCP call failed"

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)
  defp normalize_id(id), do: id
  defp to_map(value) when is_map(value), do: value
  defp to_map(_value), do: %{}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
