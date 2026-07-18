defmodule HydraAgent.Browser do
  @moduledoc """
  Browser automation session and artifact bridge.

  When a Playwright worker URL is configured, actions are sent to that worker.
  Without a worker, actions are still recorded as durable sessions/artifacts so
  operators can see that browser permission was requested.
  """

  import Ecto.Query

  alias HydraAgent.Browser.{Artifact, Session}
  alias HydraAgent.Repo
  alias HydraAgent.Runtime.{AgentProfile, Run}

  def list_sessions(workspace_id, opts \\ []) do
    Session
    |> where([session], session.workspace_id == ^normalize_id(workspace_id))
    |> maybe_filter(:status, opt(opts, :status))
    |> order_by([session], desc: session.updated_at, desc: session.id)
    |> preload([:artifacts])
    |> Repo.all()
  end

  def execute(action, input, context \\ %{}) do
    input = stringify_keys(input || %{})
    context = stringify_keys(context || %{})

    with :ok <- validate_action(action, input),
         :ok <- validate_allowed_url(action, input, context) do
      case browser_worker_url(context) do
        url when is_binary(url) and url != "" -> execute_with_worker(url, action, input, context)
        _missing -> record_without_worker(action, input, context)
      end
    end
  end

  defp execute_with_worker(worker_url, action, input, context) do
    payload = %{
      action: action,
      input: input,
      context: Map.take(context, ~w(workspace_id agent_id run_id browser_session_id))
    }

    Req.post(worker_url, json: payload)
    |> case do
      {:ok, response} when response.status in 200..299 ->
        record_worker_result(action, input, context, response.body)

      {:ok, response} ->
        {:error,
         %{
           "reason" => "browser_worker_http_error",
           "status" => response.status,
           "body" => response.body
         }}

      {:error, error} ->
        {:error, %{"reason" => inspect(error)}}
    end
  end

  defp record_without_worker(action, input, context) do
    case normalize_id(context["workspace_id"]) do
      nil ->
        {:ok, Map.merge(recorded_payload(action, input), %{"backend" => "unconfigured"})}

      workspace_id ->
        with {:ok, session} <- ensure_session(workspace_id, context, input),
             {:ok, artifact} <-
               record_step_artifact(session, action, input, %{"backend" => "unconfigured"}) do
          {:ok,
           Map.merge(recorded_payload(action, input), %{
             "backend" => "recorded",
             "browser_session_id" => session.id,
             "artifact_id" => artifact.id
           })}
        end
    end
  end

  defp record_worker_result(action, input, context, result) do
    case normalize_id(context["workspace_id"]) do
      nil ->
        {:ok,
         Map.merge(recorded_payload(action, input), %{"backend" => "worker", "result" => result})}

      workspace_id ->
        with {:ok, session} <- ensure_session(workspace_id, context, input),
             {:ok, session} <- update_session_from_worker(session, result),
             {:ok, artifact} <-
               record_step_artifact(session, action, input, %{
                 "backend" => "worker",
                 "result" => result
               }) do
          {:ok,
           Map.merge(recorded_payload(action, input), %{
             "backend" => "worker",
             "browser_session_id" => session.id,
             "artifact_id" => artifact.id,
             "result" => result
           })}
        end
    end
  end

  defp ensure_session(workspace_id, context, input) do
    with :ok <- validate_context_associations(workspace_id, context) do
      case requested_session(context) do
        {:ok, nil} ->
          %Session{}
          |> Session.changeset(%{
            "workspace_id" => workspace_id,
            "agent_id" => normalize_id(context["agent_id"]),
            "run_id" => normalize_id(context["run_id"]),
            "status" => "active",
            "current_url" => input["url"],
            "expires_at" => expires_at(),
            "metadata" => %{"created_by" => "browser_tool"}
          })
          |> Repo.insert()

        {:ok, session_id} ->
          case Repo.get_by(Session, id: session_id, workspace_id: workspace_id) do
            %Session{} = session ->
              session
              |> Session.changeset(%{
                "current_url" => input["url"] || session.current_url,
                "status" => "active",
                "expires_at" => expires_at()
              })
              |> Repo.update()

            nil ->
              {:error, %{"reason" => "browser_session_not_in_workspace"}}
          end

        {:error, reason} ->
          {:error, %{"reason" => reason}}
      end
    end
  end

  defp requested_session(context) do
    case context["browser_session_id"] do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      value ->
        case normalize_id(value) do
          id when is_integer(id) -> {:ok, id}
          _invalid -> {:error, "invalid_browser_session_id"}
        end
    end
  end

  defp validate_context_associations(workspace_id, context) do
    with :ok <-
           validate_workspace_reference(AgentProfile, workspace_id, context["agent_id"], "agent"),
         :ok <- validate_workspace_reference(Run, workspace_id, context["run_id"], "run") do
      :ok
    end
  end

  defp validate_workspace_reference(_schema, _workspace_id, value, _label)
       when value in [nil, ""],
       do: :ok

  defp validate_workspace_reference(schema, workspace_id, value, label) do
    case normalize_id(value) do
      id when is_integer(id) ->
        if Repo.exists?(
             from record in schema,
               where: record.id == ^id and record.workspace_id == ^workspace_id
           ),
           do: :ok,
           else: {:error, %{"reason" => "browser_#{label}_not_in_workspace"}}

      _invalid ->
        {:error, %{"reason" => "invalid_browser_#{label}_id"}}
    end
  end

  defp record_step_artifact(%Session{} = session, action, input, metadata) do
    %Artifact{}
    |> Artifact.changeset(%{
      "workspace_id" => session.workspace_id,
      "browser_session_id" => session.id,
      "kind" => artifact_kind(action),
      "content_type" => "application/json",
      "content" => Jason.encode!(%{"action" => action, "input" => input}),
      "metadata" => metadata
    })
    |> Repo.insert()
  end

  defp update_session_from_worker(%Session{} = session, result) when is_map(result) do
    session
    |> Session.changeset(%{
      "worker_session_id" => result["worker_session_id"] || session.worker_session_id,
      "current_url" => result["url"] || session.current_url,
      "last_error" => %{}
    })
    |> Repo.update()
  end

  defp update_session_from_worker(%Session{} = session, _result), do: {:ok, session}

  defp artifact_kind("screenshot"), do: "screenshot"
  defp artifact_kind("extract"), do: "extract"
  defp artifact_kind(_action), do: "step"

  defp recorded_payload(action, input) do
    input
    |> Map.take(~w(url selector))
    |> Map.merge(%{"action" => action, "status" => "recorded"})
  end

  defp validate_action("navigate", %{"url" => url}), do: validate_url(url)

  defp validate_action("click", %{"selector" => selector}),
    do: validate_present(selector, "selector_required")

  defp validate_action("type", %{"selector" => selector, "text" => text}) when is_binary(text),
    do: validate_present(selector, "selector_and_text_required")

  defp validate_action("extract", _input), do: :ok
  defp validate_action("screenshot", _input), do: :ok
  defp validate_action(_action, _input), do: {:error, %{"reason" => "unsupported_browser_action"}}

  defp validate_present(value, _reason) when is_binary(value) and value != "", do: :ok
  defp validate_present(_value, reason), do: {:error, %{"reason" => reason}}

  defp validate_url(url) do
    case URI.parse(url || "") do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        :ok

      _uri ->
        {:error, %{"reason" => "invalid_browser_url"}}
    end
  end

  defp validate_allowed_url("navigate", %{"url" => url}, context) do
    allowlist = List.wrap(context["browser_allowlist"] || context["network_allowlist"] || [])
    host = (URI.parse(url).host || "") |> String.downcase()

    cond do
      allowlist == [] -> :ok
      host in allowlist -> :ok
      true -> {:error, %{"reason" => "browser_url_not_allowed", "host" => host}}
    end
  end

  defp validate_allowed_url(_action, _input, _context), do: :ok

  defp browser_worker_url(context) do
    context["browser_worker_url"] || Application.get_env(:hydra_agent, :browser_worker_url)
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query

  defp maybe_filter(query, field, value),
    do: where(query, [record], field(record, ^field) == ^value)

  defp expires_at,
    do: DateTime.utc_now() |> DateTime.add(30 * 60, :second) |> DateTime.truncate(:microsecond)

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, to_string(key))

  defp normalize_id(nil), do: nil

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp normalize_id(id), do: id

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
