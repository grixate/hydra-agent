defmodule HydraAgent.Providers.OpenAICompatibleFailureInjectionTest do
  use ExUnit.Case, async: false

  alias HydraAgent.Providers
  alias HydraAgent.Runtime.ProviderConfig

  setup do
    System.put_env("HYDRA_STAGING_OPENAI_KEY", "staging-test-key")
    on_exit(fn -> System.delete_env("HYDRA_STAGING_OPENAI_KEY") end)
    :ok
  end

  test "accepts one bounded, usage-accounted structured response" do
    plug = fn conn ->
      assert ["Bearer staging-test-key"] = Plug.Conn.get_req_header(conn, "authorization")
      assert Plug.Conn.get_req_header(conn, "accept-encoding") == []

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "id" => "request-staging-1",
          "model" => "gpt-staging",
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => ~s({"status":"ok"})}}
          ],
          "usage" => %{"prompt_tokens" => 8, "completion_tokens" => 5, "total_tokens" => 13}
        })
      )
    end

    assert {:ok, response} =
             Providers.chat(provider(plug), %{
               "messages" => [%{"role" => "user", "content" => "Return JSON"}]
             })

    assert response["request_id"] == "request-staging-1"
    assert response["message"]["content"] == ~s({"status":"ok"})

    assert response["usage"] == %{
             "input_tokens" => 8,
             "output_tokens" => 5,
             "total_tokens" => 13
           }
  end

  test "classifies authentication and rate-limit responses without returning raw bodies" do
    Enum.each([{401, "invalid_api_key"}, {429, "rate_limit_exceeded"}], fn {status, code} ->
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          status,
          Jason.encode!(%{
            "error" => %{
              "code" => code,
              "type" => "provider_error",
              "message" => "bounded operator guidance",
              "raw_secret" => "must-not-escape"
            },
            "unbounded_body" => String.duplicate("x", 10_000)
          })
        )
      end

      assert {:error, error} = Providers.chat(provider(plug), %{"messages" => []})
      assert error["reason"] == "provider_http_error"
      assert error["status"] == status
      assert error["provider_code"] == code
      assert error["provider_message"] == "bounded operator guidance"
      refute inspect(error) =~ "must-not-escape"
      refute Map.has_key?(error, "body")
    end)
  end

  test "rejects malformed success responses and missing usage" do
    malformed = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"choices" => []}))
    end

    assert {:error, %{"reason" => "invalid_provider_response"}} =
             Providers.chat(provider(malformed), %{"messages" => []})

    missing_usage = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "{}"}}]
        })
      )
    end

    assert {:error, %{"reason" => "invalid_provider_response"}} =
             Providers.chat(provider(missing_usage), %{"messages" => []})
  end

  test "converts transport exceptions and oversized prompts into bounded failures" do
    broken = fn _conn -> raise "fault proxy interrupted the connection" end

    assert {:error, %{"reason" => "provider_request_failed"} = transport_error} =
             Providers.chat(provider(broken), %{"messages" => []})

    refute inspect(transport_error) =~ "fault proxy interrupted"

    assert {:error, %{"reason" => "provider_request_too_large"}} =
             Providers.chat(provider(broken), %{
               "messages" => [
                 %{"role" => "user", "content" => String.duplicate("x", 2_000_001)}
               ]
             })
  end

  test "rejects invalid token totals" do
    invalid_usage = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "{}"}}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => -1}
        })
      )
    end

    assert {:error, %{"reason" => "invalid_provider_response"}} =
             Providers.chat(provider(invalid_usage), %{"messages" => []})
  end

  defp provider(plug) do
    %ProviderConfig{
      name: "OpenAI staging adapter",
      kind: "openai_compatible",
      model: "gpt-staging",
      base_url: "http://fault-proxy.test",
      api_key_env: "HYDRA_STAGING_OPENAI_KEY",
      metadata: %{req_options: [plug: plug]}
    }
  end
end
