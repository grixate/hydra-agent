defmodule HydraAgent.Providers.AnthropicOllamaFailureInjectionTest do
  use ExUnit.Case, async: false

  alias HydraAgent.{ProviderStaging, Providers}
  alias HydraAgent.Runtime.ProviderConfig

  setup do
    System.put_env("HYDRA_STAGING_ANTHROPIC_KEY", "anthropic-staging-key")
    on_exit(fn -> System.delete_env("HYDRA_STAGING_ANTHROPIC_KEY") end)
    :ok
  end

  test "Anthropic qualifies a bounded structured probe with exact usage" do
    plug = fn conn ->
      assert ["anthropic-staging-key"] = Plug.Conn.get_req_header(conn, "x-api-key")
      assert is_binary(conn.body_params["system"])
      assert [%{"role" => "user", "content" => content}] = conn.body_params["messages"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "id" => "anthropic-probe-1",
          "model" => "claude-staging",
          "content" => [%{"type" => "text", "text" => content}],
          "usage" => %{"input_tokens" => 11, "output_tokens" => 7}
        })
      )
    end

    assert {:ok, report} = ProviderStaging.probe(anthropic_provider(plug))
    assert report["status"] == "passed"
    assert report["request_id"] == "anthropic-probe-1"
    assert report["usage"]["total_tokens"] == 18
  end

  test "Ollama qualifies a bounded structured probe with explicit generation limits" do
    plug = fn conn ->
      assert conn.body_params["options"] == %{"temperature" => 0, "num_predict" => 100}
      [%{"content" => content}] = Enum.take(conn.body_params["messages"], -1)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "model" => "local-staging",
          "message" => %{"role" => "assistant", "content" => content},
          "prompt_eval_count" => 9,
          "eval_count" => 6
        })
      )
    end

    assert {:ok, report} = ProviderStaging.probe(ollama_provider(plug))
    assert report["status"] == "passed"
    assert report["usage"]["total_tokens"] == 15
  end

  test "Anthropic and Ollama bound HTTP failures and reject missing usage" do
    Enum.each(
      [anthropic_provider(&error_response/1), ollama_provider(&error_response/1)],
      fn provider ->
        assert {:error, error} = Providers.chat(provider, %{"messages" => []})
        assert error["reason"] == "provider_http_error"
        assert error["status"] == 429
        refute Map.has_key?(error, "body")
        refute inspect(error) =~ "must-not-escape"
      end
    )

    assert {:error, %{"reason" => "invalid_provider_response"}} =
             Providers.chat(anthropic_provider(&anthropic_without_usage/1), %{"messages" => []})

    assert {:error, %{"reason" => "invalid_provider_response"}} =
             Providers.chat(ollama_provider(&ollama_without_usage/1), %{"messages" => []})
  end

  test "transport exceptions are normalized without exposing exception content" do
    broken = fn _conn -> raise "internal provider proxy path must-not-escape" end

    Enum.each([anthropic_provider(broken), ollama_provider(broken)], fn provider ->
      assert {:error, %{"reason" => "provider_request_failed"} = error} =
               Providers.chat(provider, %{"messages" => []})

      refute inspect(error) =~ "must-not-escape"
    end)
  end

  defp error_response(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      429,
      Jason.encode!(%{
        "error" => %{
          "type" => "rate_limit_error",
          "message" => "Retry after the provider window",
          "private" => "must-not-escape"
        }
      })
    )
  end

  defp anthropic_without_usage(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{"content" => [%{"type" => "text", "text" => "{}"}]})
    )
  end

  defp ollama_without_usage(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{"message" => %{"role" => "assistant", "content" => "{}"}})
    )
  end

  defp anthropic_provider(plug) do
    %ProviderConfig{
      name: "Anthropic staging adapter",
      kind: "anthropic",
      model: "claude-staging",
      base_url: "http://anthropic-fault-proxy.test",
      api_key_env: "HYDRA_STAGING_ANTHROPIC_KEY",
      metadata: %{req_options: [plug: plug]}
    }
  end

  defp ollama_provider(plug) do
    %ProviderConfig{
      name: "Ollama staging adapter",
      kind: "ollama",
      model: "local-staging",
      base_url: "http://ollama-fault-proxy.test",
      metadata: %{req_options: [plug: plug]}
    }
  end
end
