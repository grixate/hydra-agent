defmodule HydraAgent.CLI do
  @moduledoc """
  Small JSON-API backed CLI for operating Hydra without the web admin UI.
  """

  @default_base_url "http://localhost:4000"

  def main(argv \\ []) do
    argv
    |> run()
    |> case do
      {:ok, output} ->
        IO.puts(output)
        0

      {:error, error} ->
        IO.puts(:stderr, format_error(error))
        1
    end
  end

  def run(["plugins", "list" | argv]) do
    with {:ok, opts, []} <- parse(argv, strict: [workspace: :string, status: :string]),
         {:ok, workspace_id} <- required(opts, :workspace) do
      query = query_string(%{"status" => opts[:status]})
      request(:get, "/api/v1/workspaces/#{workspace_id}/plugins#{query}")
    end
  end

  def run(["plugins", "schema" | argv]) do
    with {:ok, _opts, []} <- parse(argv, strict: []) do
      request(:get, "/api/v1/plugins/manifest_schema")
    end
  end

  def run(["plugins", "web-routes" | argv]) do
    run(["plugins", "client-surfaces" | argv])
  end

  def run(["plugins", "client-surfaces" | argv]) do
    with {:ok, opts, []} <- parse(argv, strict: [workspace: :string]),
         {:ok, workspace_id} <- required(opts, :workspace) do
      request(:get, "/api/v1/workspaces/#{workspace_id}/plugins/client_surfaces")
    end
  end

  def run(["plugins", "client-contract" | argv]) do
    with {:ok, opts, []} <- parse(argv, strict: [workspace: :string]),
         {:ok, workspace_id} <- required(opts, :workspace) do
      request(:get, "/api/v1/workspaces/#{workspace_id}/plugins/client_contract")
    end
  end

  def run(["plugins", "scan" | argv]) do
    with {:ok, opts, []} <-
           parse(argv,
             strict: [workspace: :string, path: :string, source_url: :string, source_ref: :string]
           ),
         {:ok, workspace_id} <- required(opts, :workspace),
         {:ok, body} <- plugin_source_body(opts) do
      request(:post, "/api/v1/workspaces/#{workspace_id}/plugins/scan", body)
    end
  end

  def run(["plugins", "install" | argv]) do
    with {:ok, opts, []} <-
           parse(argv,
             strict: [
               workspace: :string,
               path: :string,
               source_url: :string,
               source_ref: :string,
               approved_by: :string
             ]
           ),
         {:ok, workspace_id} <- required(opts, :workspace),
         {:ok, source_body} <- plugin_source_body(opts),
         {:ok, approved_by} <- required(opts, :approved_by) do
      request(
        :post,
        "/api/v1/workspaces/#{workspace_id}/plugins/install",
        Map.put(source_body, "approved_by", approved_by)
      )
    end
  end

  def run(["plugins", "enable" | argv]) do
    with {:ok, opts, []} <-
           parse(argv, strict: [workspace: :string, id: :string, approved_by: :string]),
         {:ok, workspace_id} <- required(opts, :workspace),
         {:ok, id} <- required(opts, :id),
         {:ok, approved_by} <- required(opts, :approved_by) do
      request(:post, "/api/v1/workspaces/#{workspace_id}/plugins/#{id}/enable", %{
        "approved_by" => approved_by
      })
    end
  end

  def run(["plugins", "disable" | argv]) do
    with {:ok, opts, []} <- parse(argv, strict: [workspace: :string, id: :string, actor: :string]),
         {:ok, workspace_id} <- required(opts, :workspace),
         {:ok, id} <- required(opts, :id) do
      request(:post, "/api/v1/workspaces/#{workspace_id}/plugins/#{id}/disable", %{
        "actor" => opts[:actor] || "operator"
      })
    end
  end

  def run(["plugins", "upgrade" | argv]) do
    with {:ok, opts, []} <-
           parse(argv,
             strict: [
               workspace: :string,
               id: :string,
               path: :string,
               source_url: :string,
               source_ref: :string,
               approved_by: :string
             ]
           ),
         {:ok, workspace_id} <- required(opts, :workspace),
         {:ok, id} <- required(opts, :id),
         {:ok, source_body} <- plugin_source_body(opts),
         {:ok, approved_by} <- required(opts, :approved_by) do
      request(
        :post,
        "/api/v1/workspaces/#{workspace_id}/plugins/#{id}/upgrade",
        Map.put(source_body, "approved_by", approved_by)
      )
    end
  end

  def run(["plugins", "uninstall" | argv]) do
    with {:ok, opts, []} <-
           parse(argv, strict: [workspace: :string, id: :string, approved_by: :string]),
         {:ok, workspace_id} <- required(opts, :workspace),
         {:ok, id} <- required(opts, :id),
         {:ok, approved_by} <- required(opts, :approved_by) do
      request(:post, "/api/v1/workspaces/#{workspace_id}/plugins/#{id}/uninstall", %{
        "approved_by" => approved_by
      })
    end
  end

  def run(["plugins", "doctor" | argv]) do
    with {:ok, opts, []} <- parse(argv, strict: [workspace: :string, id: :string]),
         {:ok, workspace_id} <- required(opts, :workspace),
         {:ok, id} <- required(opts, :id) do
      request(:get, "/api/v1/workspaces/#{workspace_id}/plugins/#{id}/doctor")
    end
  end

  def run(["plugins", "config" | argv]) do
    with {:ok, opts, []} <- parse(argv, strict: [workspace: :string, id: :string]),
         {:ok, workspace_id} <- required(opts, :workspace),
         {:ok, id} <- required(opts, :id) do
      request(:get, "/api/v1/workspaces/#{workspace_id}/plugins/#{id}/config")
    end
  end

  def run(["plugins", "configure" | argv]) do
    with {:ok, opts, []} <-
           parse(argv,
             strict: [
               workspace: :string,
               id: :string,
               config_json: :string,
               configured_by: :string
             ]
           ),
         {:ok, workspace_id} <- required(opts, :workspace),
         {:ok, id} <- required(opts, :id),
         {:ok, config_json} <- required(opts, :config_json),
         {:ok, config} <- decode_json(config_json) do
      request(:put, "/api/v1/workspaces/#{workspace_id}/plugins/#{id}/config", %{
        "config" => config,
        "configured_by" => opts[:configured_by] || "operator"
      })
    end
  end

  def run(["help" | _argv]), do: {:ok, usage()}
  def run([]), do: {:ok, usage()}
  def run(_argv), do: {:error, %{"reason" => "unknown_command", "usage" => usage()}}

  defp parse(argv, opts) do
    case OptionParser.parse(argv, opts) do
      {opts, args, []} -> {:ok, opts, args}
      {_opts, _args, invalid} -> {:error, %{"reason" => "invalid_options", "options" => invalid}}
    end
  end

  defp required(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, %{"reason" => "missing_required_option", "option" => "--#{key}"}}
    end
  end

  defp plugin_source_body(opts) do
    cond do
      present?(opts[:path]) ->
        {:ok, %{"path" => opts[:path]}}

      present?(opts[:source_url]) and present?(opts[:source_ref]) ->
        {:ok, %{"source_url" => opts[:source_url], "source_ref" => opts[:source_ref]}}

      true ->
        {:error,
         %{
           "reason" => "missing_plugin_source",
           "detail" => "provide --path or both --source-url and --source-ref"
         }}
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _decoded} ->
        {:error,
         %{"reason" => "invalid_json", "detail" => "--config-json must decode to an object"}}

      {:error, error} ->
        {:error, %{"reason" => "invalid_json", "error" => Exception.message(error)}}
    end
  end

  defp request(method, path, body \\ nil) do
    url = base_url() <> path

    req_opts =
      [
        url: url,
        method: method,
        headers: headers(),
        receive_timeout: 60_000
      ]
      |> maybe_json(body)

    case Req.request(req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, Jason.encode!(body, pretty: true)}

      {:ok, %{status: status, body: body}} ->
        {:error, %{"reason" => "api_error", "status" => status, "body" => body}}

      {:error, error} ->
        {:error, %{"reason" => "request_failed", "error" => Exception.message(error)}}
    end
  end

  defp maybe_json(opts, nil), do: opts
  defp maybe_json(opts, body), do: Keyword.put(opts, :json, body)

  defp headers do
    case System.get_env("HYDRA_API_TOKEN") do
      nil -> []
      "" -> []
      token -> [{"authorization", "Bearer #{token}"}]
    end
  end

  defp base_url do
    System.get_env("HYDRA_URL") || @default_base_url
  end

  defp query_string(params) do
    params = params |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)

    case params do
      [] -> ""
      params -> "?" <> URI.encode_query(params)
    end
  end

  defp format_error(%{"usage" => usage} = error),
    do: Jason.encode!(Map.delete(error, "usage"), pretty: true) <> "\n\n" <> usage

  defp format_error(error) when is_map(error), do: Jason.encode!(error, pretty: true)
  defp format_error(error), do: inspect(error)

  defp usage do
    """
    Usage:
      hydra plugins list --workspace ID [--status enabled]
      hydra plugins schema
      hydra plugins client-surfaces --workspace ID
      hydra plugins client-contract --workspace ID
      hydra plugins scan --workspace ID --path PATH
      hydra plugins scan --workspace ID --source-url URL --source-ref COMMIT_SHA
      hydra plugins install --workspace ID --path PATH --approved-by ACTOR
      hydra plugins install --workspace ID --source-url URL --source-ref COMMIT_SHA --approved-by ACTOR
      hydra plugins enable --workspace ID --id ID --approved-by ACTOR
      hydra plugins disable --workspace ID --id ID [--actor ACTOR]
      hydra plugins upgrade --workspace ID --id ID --path PATH --approved-by ACTOR
      hydra plugins uninstall --workspace ID --id ID --approved-by ACTOR
      hydra plugins doctor --workspace ID --id ID
      hydra plugins config --workspace ID --id ID
      hydra plugins configure --workspace ID --id ID --config-json JSON [--configured-by ACTOR]

    Environment:
      HYDRA_URL        API base URL, defaults to #{@default_base_url}
      HYDRA_API_TOKEN  Optional bearer token for API auth
    """
    |> String.trim()
  end
end
