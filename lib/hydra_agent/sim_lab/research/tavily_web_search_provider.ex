defmodule HydraAgent.SimLab.Research.TavilyWebSearchProvider do
  @moduledoc """
  Advanced web-search adapter for Tavily's agent-oriented Search API.

  Only the abstracted `safe_query` leaves Hydra. Results remain reviewable
  candidates with source URLs; Tavily's optional generated answer and raw page
  content are deliberately disabled to keep provenance narrow and bounded.
  """

  @behaviour HydraAgent.SimLab.Research.WebSearchProvider

  alias HydraAgent.Security.BoundedJsonHttp

  @default_endpoint "https://api.tavily.com/search"
  @default_key_env "TAVILY_API_KEY"
  @max_query_chars 1_000
  @max_results 5
  @max_title_chars 300
  @max_snippet_chars 10_000

  @impl true
  def search(%{safe_query: safe_query} = lane) when is_binary(safe_query) do
    with {:ok, query} <- normalize_query(safe_query),
         {:ok, api_key} <- api_key(),
         {:ok, response} <- request(api_key, request_body(lane, query)),
         {:ok, body} <- BoundedJsonHttp.decode_body(response.body),
         response = %{response | body: body},
         {:ok, results} <- normalize_response(response) do
      {:ok, results}
    end
  end

  def search(_lane), do: {:error, :invalid_research_lane}

  def configured?, do: match?({:ok, _key}, api_key())

  defp api_key do
    env_name = Map.get(config(), :api_key_env, @default_key_env)

    case env_name do
      env_name when is_binary(env_name) and env_name != "" ->
        case System.get_env(env_name) do
          key when is_binary(key) and key != "" -> {:ok, key}
          _ -> {:error, :tavily_not_configured}
        end

      _ ->
        {:error, :tavily_not_configured}
    end
  end

  defp request(api_key, body) do
    options = [
      headers: [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"},
        {"accept", "application/json"}
      ],
      json: body,
      receive_timeout: config()[:timeout_ms] || 30_000
    ]

    request_options =
      [requester: config()[:requester]]
      |> maybe_put_resolver(config()[:resolver])

    case BoundedJsonHttp.request(
           :post,
           config()[:endpoint] || @default_endpoint,
           options,
           request_options
         ) do
      {:ok, %{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %{status: 401}} -> {:error, :tavily_unauthorized}
      {:ok, %{status: 429}} -> {:error, :tavily_rate_limited}
      {:ok, %{status: status}} -> {:error, {:tavily_status, status}}
      {:error, reason} -> {:error, {:tavily_request_failed, reason}}
      _ -> {:error, :invalid_tavily_response}
    end
  end

  defp request_body(lane, query) do
    %{
      query: query,
      topic: if(lane.lane == "recent_news", do: "news", else: "general"),
      search_depth: "advanced",
      chunks_per_source: 3,
      max_results: @max_results,
      include_answer: false,
      include_raw_content: false,
      include_images: false,
      auto_parameters: false
    }
  end

  defp normalize_response(%{body: %{"results" => results}}) when is_list(results) do
    normalized =
      results
      |> Stream.flat_map(fn result ->
        with title when is_binary(title) <- Map.get(result, "title"),
             url when is_binary(url) <- Map.get(result, "url"),
             content when is_binary(content) <- Map.get(result, "content"),
             true <- public_https_url?(url),
             true <- String.trim(title) != "" and String.trim(content) != "" do
          [
            %{
              title: String.slice(String.trim(title), 0, @max_title_chars),
              url: String.trim(url),
              snippet: String.slice(String.trim(content), 0, @max_snippet_chars),
              reliability: reliability(Map.get(result, "score")),
              provider_mode: "tavily_advanced_search",
              source_kind: "web",
              grounding_level: "external_research"
            }
          ]
        else
          _ -> []
        end
      end)
      |> Enum.take(@max_results)

    if normalized == [], do: {:error, :empty_tavily_results}, else: {:ok, normalized}
  end

  defp normalize_response(_response), do: {:error, :invalid_tavily_response}

  defp public_https_url?(url) do
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

  defp normalize_query(query) do
    case String.trim(query) do
      "" -> {:error, :invalid_research_lane}
      trimmed -> {:ok, String.slice(trimmed, 0, @max_query_chars)}
    end
  end

  defp reliability(score) when is_number(score) and score >= 0.75, do: "high"
  defp reliability(score) when is_number(score) and score >= 0.45, do: "medium"
  defp reliability(_score), do: "low"

  defp config do
    Application.get_env(:hydra_agent, :sim_lab_tavily, []) |> Map.new()
  end

  defp maybe_put_resolver(options, resolver) when is_function(resolver, 1),
    do: Keyword.put(options, :resolver, resolver)

  defp maybe_put_resolver(options, _resolver), do: options
end
