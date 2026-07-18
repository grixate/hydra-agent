defmodule HydraAgent.SimLab.Research.ConfiguredWebSearchProvider do
  @moduledoc """
  A fail-closed HTTP adapter for a configured search service.

  It transmits only the `safe_query` produced by the research planner. The
  adapter intentionally has no default endpoint or fallback data: an operator
  must configure a provider before external research is allowed to run.
  """

  @behaviour HydraAgent.SimLab.Research.WebSearchProvider

  alias HydraAgent.Security.BoundedJsonHttp

  @max_query_chars 1_000
  @max_results 10
  @max_title_chars 300
  @max_snippet_chars 10_000

  @impl true
  def search(%{safe_query: safe_query} = lane) when is_binary(safe_query) do
    with {:ok, query} <- normalize_query(safe_query),
         {:ok, endpoint} <- endpoint(),
         {:ok, headers} <- auth_headers(),
         {:ok, response} <- request(endpoint, headers, query, lane),
         {:ok, body} <- BoundedJsonHttp.decode_body(response.body),
         {:ok, results} <- normalize_results(body) do
      {:ok, results}
    end
  end

  def search(_lane), do: {:error, :invalid_research_lane}

  def configured? do
    match?({:ok, _endpoint}, endpoint()) and match?({:ok, _headers}, auth_headers())
  end

  defp endpoint do
    case Application.get_env(:hydra_agent, :sim_lab_web_search, %{})
         |> Map.new()
         |> Map.get(:endpoint) do
      endpoint when is_binary(endpoint) and endpoint != "" -> {:ok, endpoint}
      _ -> {:error, :not_configured}
    end
  end

  defp request(endpoint, headers, query, lane) do
    options = [
      params: %{
        q: query,
        region: bounded_value(Map.get(lane, :region), 120),
        language: bounded_value(Map.get(lane, :language), 24)
      },
      headers: [{"accept", "application/json"} | headers],
      receive_timeout: config()[:timeout_ms] || 30_000
    ]

    request_options =
      [requester: config()[:requester]]
      |> maybe_put_resolver(config()[:resolver])

    case BoundedJsonHttp.request(:get, endpoint, options, request_options) do
      {:ok, %{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %{status: status}} -> {:error, {:provider_status, status}}
      {:error, reason} -> {:error, {:provider_request_failed, reason}}
    end
  end

  defp auth_headers do
    case config()[:api_key_env] do
      env when is_binary(env) and env != "" ->
        case System.get_env(env) do
          key when is_binary(key) and key != "" ->
            {:ok, [{"authorization", "Bearer #{key}"}]}

          _ ->
            {:error, :provider_credential_not_configured}
        end

      _ ->
        {:ok, []}
    end
  end

  defp normalize_results(%{"results" => results}) when is_list(results) do
    normalized = normalize_result_list(results)
    if normalized == [], do: {:error, :empty_provider_results}, else: {:ok, normalized}
  end

  defp normalize_results(%{results: results}) when is_list(results) do
    normalized = normalize_result_list(results)
    if normalized == [], do: {:error, :empty_provider_results}, else: {:ok, normalized}
  end

  defp normalize_results(_), do: {:error, :invalid_provider_response}

  defp normalize_result_list(results) do
    results
    |> Stream.flat_map(&normalize_result/1)
    |> Enum.take(@max_results)
  end

  defp normalize_result(result) when is_map(result) do
    with title when is_binary(title) <- Map.get(result, "title") || Map.get(result, :title),
         url when is_binary(url) <- Map.get(result, "url") || Map.get(result, :url),
         snippet when is_binary(snippet) <-
           Map.get(result, "snippet") || Map.get(result, :snippet) || "",
         true <- String.trim(title) != "" and String.trim(snippet) != "",
         true <- valid_https_result_url?(url) do
      [
        %{
          title: title |> String.trim() |> String.slice(0, @max_title_chars),
          url: String.trim(url),
          snippet: snippet |> String.trim() |> String.slice(0, @max_snippet_chars),
          reliability:
            normalize_reliability(Map.get(result, "reliability") || Map.get(result, :reliability))
        }
      ]
    else
      _ -> []
    end
  end

  defp normalize_result(_result), do: []

  defp normalize_query(query) do
    case String.trim(query) do
      "" -> {:error, :invalid_research_lane}
      trimmed -> {:ok, String.slice(trimmed, 0, @max_query_chars)}
    end
  end

  defp bounded_value(value, max_chars) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, max_chars)

  defp bounded_value(_value, _max_chars), do: ""

  defp valid_https_result_url?(url) do
    case URI.new(String.trim(url)) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}}
      when is_binary(host) and host != "" ->
        valid_hostname?(host)

      _ ->
        false
    end
  end

  defp valid_hostname?(host) do
    String.length(host) <= 253 and String.contains?(host, ".") and not local_hostname?(host) and
      not ip_literal?(host) and
      Regex.match?(
        ~r/^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$/,
        host
      )
  end

  defp local_hostname?(host) do
    host = String.downcase(host)

    host == "localhost" or
      Enum.any?([".local", ".localhost", ".internal", ".lan"], &String.ends_with?(host, &1))
  end

  defp ip_literal?(host),
    do: match?({:ok, _address}, :inet.parse_address(String.to_charlist(host)))

  defp normalize_reliability(value) when value in ["high", "medium", "low", "unknown"], do: value
  defp normalize_reliability(_value), do: "unknown"

  defp maybe_put_resolver(options, resolver) when is_function(resolver, 1),
    do: Keyword.put(options, :resolver, resolver)

  defp maybe_put_resolver(options, _resolver), do: options

  defp config do
    Application.get_env(:hydra_agent, :sim_lab_web_search, %{}) |> Map.new()
  end
end
