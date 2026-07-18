defmodule HydraAgent.SimLab.ResearchProvidersTest do
  use ExUnit.Case, async: false

  alias HydraAgent.SimLab.Research.{
    CodexCliTestProvider,
    ConfiguredWebSearchProvider,
    Runner,
    TavilyWebSearchProvider,
    WebResearchPlanner
  }

  setup do
    original_environment = Application.get_env(:hydra_agent, :environment)
    original_codex = Application.get_env(:hydra_agent, :sim_lab_codex_cli)
    original_tavily = Application.get_env(:hydra_agent, :sim_lab_tavily)
    original_web_search = Application.get_env(:hydra_agent, :sim_lab_web_search)
    original_codex_flag = System.get_env("HYDRA_SIM_CODEX_CLI_TESTING")
    original_tavily_key = System.get_env("TAVILY_API_KEY")
    original_web_search_key = System.get_env("HYDRA_SEARCH_TEST_KEY")

    on_exit(fn ->
      restore_app_env(:environment, original_environment)
      restore_app_env(:sim_lab_codex_cli, original_codex)
      restore_app_env(:sim_lab_tavily, original_tavily)
      restore_app_env(:sim_lab_web_search, original_web_search)
      restore_system_env("HYDRA_SIM_CODEX_CLI_TESTING", original_codex_flag)
      restore_system_env("TAVILY_API_KEY", original_tavily_key)
      restore_system_env("HYDRA_SEARCH_TEST_KEY", original_web_search_key)
    end)

    :ok
  end

  test "Codex CLI test mode batches safe lanes and persists only synthetic assumptions" do
    lanes = planned_lanes()
    parent = self()

    runner = fn prompt ->
      send(parent, {:codex_prompt, prompt})

      results =
        Enum.map(lanes, fn lane ->
          %{
            "lane" => lane.lane,
            "title" => "Test hypothesis for #{lane.lane}",
            "snippet" => "A cautious #{lane.lane} hypothesis that requires validation."
          }
        end)

      message = Jason.encode!(%{"results" => results})

      Jason.encode!(%{
        "type" => "item.completed",
        "item" => %{"type" => "agent_message", "text" => message}
      })
    end

    enable_codex(runner)

    assert {:ok, grouped} = CodexCliTestProvider.search_many(lanes)
    assert map_size(grouped) == length(lanes)
    assert_receive {:codex_prompt, prompt}
    refute prompt =~ "Acme"
    assert prompt =~ "SYNTHETIC TEST HYPOTHESES"

    output =
      Runner.run(
        "How will Acme employees react to visible certificates?",
        %{region: "Germany"},
        CodexCliTestProvider,
        private_entities: ["Acme"]
      )

    assert length(output.evidence) == 7
    assert Enum.all?(output.evidence, &(&1.grounding_level == "assumption"))
    assert Enum.all?(output.sources, &(&1.kind == "manual_note" and is_nil(&1.uri)))
    assert output.context_pack.summary["research_status"] == "synthetic_test_hypotheses"
    assert output.context_pack.source_mix == %{"external_research" => 0, "assumptions" => 7}
    assert length(output.context_pack.assumptions) == 7
    assert output.context_pack.confidence <= 0.2
  end

  test "Codex CLI test mode fails closed when disabled or when a lane is missing" do
    Application.put_env(:hydra_agent, :environment, :test)
    Application.put_env(:hydra_agent, :sim_lab_codex_cli, enabled?: true)
    System.delete_env("HYDRA_SIM_CODEX_CLI_TESTING")

    assert {:error, :codex_cli_test_disabled} =
             CodexCliTestProvider.search_many(planned_lanes())

    [first | _] = lanes = planned_lanes()

    enable_codex(fn _prompt ->
      Jason.encode!(%{
        "results" => [
          %{
            "lane" => first.lane,
            "title" => "Only one lane",
            "snippet" => "Incomplete output must not enter the evidence store."
          }
        ]
      })
    end)

    assert {:error, :incomplete_codex_cli_result} = CodexCliTestProvider.search_many(lanes)
  end

  test "Tavily adapter sends an advanced bounded safe query and normalizes HTTPS sources" do
    parent = self()
    System.put_env("TAVILY_API_KEY", "tvly-test")

    requester = fn options ->
      send(parent, {:tavily_options, options})

      {:ok,
       %{
         status: 200,
         body: %{
           "results" => [
             %{
               "title" => String.duplicate("Published adoption study ", 20),
               "url" => "https://research.example/adoption",
               "content" => String.duplicate("Trust evidence. ", 1_000),
               "score" => 0.82
             },
             %{
               "title" => "Unsafe result",
               "url" => "http://internal.example/report",
               "content" => "This must be discarded.",
               "score" => 0.99
             },
             %{
               "title" => "Private-link result",
               "url" => "https://127.0.0.1/report",
               "content" => "This must also be discarded.",
               "score" => 0.99
             }
           ]
         }
       }}
    end

    Application.put_env(:hydra_agent, :sim_lab_tavily,
      endpoint: "https://api.tavily.test/search",
      api_key_env: "TAVILY_API_KEY",
      resolver: public_resolver(),
      requester: requester
    )

    lane = %{hd(planned_lanes()) | safe_query: String.duplicate("bounded query ", 200)}
    assert {:ok, [result]} = TavilyWebSearchProvider.search(lane)
    assert result.url == "https://research.example/adoption"
    assert result.reliability == "high"
    assert result.grounding_level == "external_research"
    assert String.length(result.title) == 300
    assert String.length(result.snippet) == 10_000

    assert_receive {:tavily_options, options}
    assert String.length(options[:json].query) == 1_000
    assert options[:json].search_depth == "advanced"
    assert options[:json].chunks_per_source == 3
    assert options[:json].max_results == 5
    assert options[:json].include_answer == false
    assert {"authorization", "Bearer tvly-test"} in options[:headers]
    assert {"host", "api.tavily.test"} in options[:headers]
    assert options[:url] == "https://93.184.216.34/search"
    assert options[:connect_options][:hostname] == "api.tavily.test"
    assert options[:redirect] == false
    assert options[:retry] == false
    assert options[:compressed] == false
    assert options[:decode_body] == false
    assert is_function(options[:into], 2)
  end

  test "Tavily adapter rejects mixed DNS and bounds streamed bodies and result count" do
    System.put_env("TAVILY_API_KEY", "tvly-test")

    Application.put_env(:hydra_agent, :sim_lab_tavily,
      endpoint: "https://mixed.tavily.test/search",
      resolver: fn _host -> {:ok, [{93, 184, 216, 34}, {10, 0, 0, 4}]} end,
      requester: fn _options -> flunk("mixed public/private DNS must not be requested") end
    )

    assert {:error, {:tavily_request_failed, :non_public_host}} =
             TavilyWebSearchProvider.search(hd(planned_lanes()))

    Application.put_env(:hydra_agent, :sim_lab_tavily,
      endpoint: "https://api.tavily.test/search",
      resolver: public_resolver(),
      requester: fn options ->
        response = %{status: 200, headers: [], body: ""}

        assert {:halt, {_request, bounded_response}} =
                 options[:into].(
                   {:data, String.duplicate("x", 1_000_001)},
                   {Req.new(), response}
                 )

        {:ok, bounded_response}
      end
    )

    assert {:error, {:tavily_request_failed, :response_too_large}} =
             TavilyWebSearchProvider.search(hd(planned_lanes()))

    Application.put_env(:hydra_agent, :sim_lab_tavily,
      endpoint: "https://api.tavily.test/search",
      resolver: public_resolver(),
      requester: fn _options ->
        {:ok,
         %{
           status: 200,
           body: %{
             "results" =>
               Enum.map(1..12, fn index ->
                 %{
                   "title" => "Result #{index}",
                   "url" => "https://research.example/#{index}",
                   "content" => "Evidence #{index}",
                   "score" => 0.6
                 }
               end)
           }
         }}
      end
    )

    assert {:ok, results} = TavilyWebSearchProvider.search(hd(planned_lanes()))
    assert length(results) == 5
  end

  test "Tavily adapter fails closed without a credential" do
    System.delete_env("TAVILY_API_KEY")
    Application.put_env(:hydra_agent, :sim_lab_tavily, api_key_env: "TAVILY_API_KEY")

    assert {:error, :tavily_not_configured} =
             TavilyWebSearchProvider.search(hd(planned_lanes()))
  end

  test "configured adapter pins public HTTPS, requires configured credentials, and bounds output" do
    parent = self()
    System.put_env("HYDRA_SEARCH_TEST_KEY", "generic-test")

    requester = fn options ->
      send(parent, {:configured_options, options})

      valid_results =
        Enum.map(1..12, fn index ->
          %{
            "title" => String.duplicate("Result #{index} ", 80),
            "url" => "https://results.example/#{index}",
            "snippet" => String.duplicate("Bounded evidence. ", 700),
            "reliability" => "high"
          }
        end)

      {:ok,
       %{
         status: 200,
         body: %{
           "results" => [
             %{
               "title" => "Insecure",
               "url" => "http://internal.example/report",
               "snippet" => "Must be discarded"
             },
             %{
               "title" => "Malformed",
               "url" => "https://bad host/report",
               "snippet" => "Must also be discarded"
             },
             %{
               "title" => "Private link",
               "url" => "https://localhost/report",
               "snippet" => "Must never be surfaced"
             }
             | valid_results
           ]
         }
       }}
    end

    Application.put_env(:hydra_agent, :sim_lab_web_search,
      endpoint: "https://search.provider.test/v1/search",
      api_key_env: "HYDRA_SEARCH_TEST_KEY",
      resolver: public_resolver(),
      requester: requester
    )

    assert ConfiguredWebSearchProvider.configured?()

    lane = %{
      safe_query: String.duplicate("abstract query ", 200),
      region: String.duplicate("region", 40),
      language: String.duplicate("en", 20)
    }

    assert {:ok, results} = ConfiguredWebSearchProvider.search(lane)
    assert length(results) == 10
    assert Enum.all?(results, &String.starts_with?(&1.url, "https://results.example/"))
    assert Enum.all?(results, &(String.length(&1.title) <= 300))
    assert Enum.all?(results, &(String.length(&1.snippet) <= 10_000))

    assert_receive {:configured_options, options}
    assert options[:url] == "https://93.184.216.34/v1/search"
    assert options[:params].q |> String.length() == 1_000
    assert options[:params].region |> String.length() == 120
    assert options[:params].language |> String.length() == 24
    assert {"authorization", "Bearer generic-test"} in options[:headers]
    assert {"host", "search.provider.test"} in options[:headers]
    assert options[:connect_options][:hostname] == "search.provider.test"
    assert options[:redirect] == false
    assert options[:retry] == false
    assert is_function(options[:into], 2)
  end

  test "configured adapter fails closed for a missing key and private endpoint DNS" do
    System.delete_env("HYDRA_SEARCH_TEST_KEY")

    Application.put_env(:hydra_agent, :sim_lab_web_search,
      endpoint: "https://search.provider.test/v1/search",
      api_key_env: "HYDRA_SEARCH_TEST_KEY",
      requester: fn _options -> flunk("missing credentials must prevent requests") end
    )

    refute ConfiguredWebSearchProvider.configured?()

    assert {:error, :provider_credential_not_configured} =
             ConfiguredWebSearchProvider.search(%{
               safe_query: "safe query",
               region: "EU",
               language: "en"
             })

    Application.put_env(:hydra_agent, :sim_lab_web_search,
      endpoint: "https://search.provider.test/v1/search",
      resolver: fn _host -> {:ok, [{192, 168, 1, 9}]} end,
      requester: fn _options -> flunk("private DNS must prevent requests") end
    )

    assert {:error, {:provider_request_failed, :non_public_host}} =
             ConfiguredWebSearchProvider.search(%{
               safe_query: "safe query",
               region: "EU",
               language: "en"
             })
  end

  defp planned_lanes do
    %{
      domain: "corporate learning",
      target_audience: "employees",
      change: "visibility settings",
      region: "Germany",
      language: "en"
    }
    |> WebResearchPlanner.plan(private_entities: ["Acme"])
  end

  defp enable_codex(runner) do
    Application.put_env(:hydra_agent, :environment, :test)
    Application.put_env(:hydra_agent, :sim_lab_codex_cli, enabled?: true, runner: runner)
    System.put_env("HYDRA_SIM_CODEX_CLI_TESTING", "1")
  end

  defp public_resolver, do: fn _host -> {:ok, [{93, 184, 216, 34}]} end

  defp restore_app_env(key, nil), do: Application.delete_env(:hydra_agent, key)
  defp restore_app_env(key, value), do: Application.put_env(:hydra_agent, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
