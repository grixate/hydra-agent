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

    started_at = System.monotonic_time()

    result =
      worker_url
      |> Req.post(
        json: payload,
        headers: worker_auth_headers(),
        receive_timeout: worker_receive_timeout_ms(),
        retry: false
      )
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

    emit_worker_telemetry(action, result, started_at)
    result
  end

  def worker_auth_headers do
    case worker_token() do
      token when is_binary(token) and token != "" -> [{"authorization", "Bearer #{token}"}]
      _missing -> []
    end
  end

  def worker_auth_required? do
    :hydra_agent
    |> Application.get_env(:browser_worker, [])
    |> Keyword.get(:auth_required?, false)
  end

  def worker_token_env do
    :hydra_agent
    |> Application.get_env(:browser_worker, [])
    |> Keyword.get(:token_env, "HYDRA_BROWSER_WORKER_TOKEN")
  end

  def worker_token_configured? do
    case worker_token() do
      token when is_binary(token) and token != "" -> true
      _missing -> false
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
    case normalize_id(context["browser_session_id"]) &&
           Repo.get(Session, normalize_id(context["browser_session_id"])) do
      %Session{} = session ->
        session
        |> Session.changeset(%{
          "current_url" => input["url"] || session.current_url,
          "status" => "active",
          "expires_at" => expires_at()
        })
        |> Repo.update()

      _none ->
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

  defp worker_token do
    worker_token_env()
    |> case do
      env when is_binary(env) and env != "" -> System.get_env(env)
      _missing -> nil
    end
  end

  defp worker_receive_timeout_ms do
    :hydra_agent
    |> Application.get_env(:browser_worker, [])
    |> Keyword.get(:receive_timeout_ms, 35_000)
  end

  defp emit_worker_telemetry(action, result, started_at) do
    status =
      case result do
        {:ok, _payload} -> :ok
        {:error, _reason} -> :error
      end

    :telemetry.execute(
      [:hydra_agent, :browser, :action, :stop],
      %{duration: System.monotonic_time() - started_at},
      %{action: action, backend: :worker, status: status}
    )
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
