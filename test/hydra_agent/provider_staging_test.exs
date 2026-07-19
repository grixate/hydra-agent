defmodule HydraAgent.ProviderStagingTest do
  use ExUnit.Case, async: false

  alias HydraAgent.ProviderStaging
  alias HydraAgent.Runtime.ProviderConfig

  setup do
    System.put_env("HYDRA_PROVIDER_PROBE_KEY", "probe-test-key")
    on_exit(fn -> System.delete_env("HYDRA_PROVIDER_PROBE_KEY") end)
    :ok
  end

  test "qualifies exact structured output and normalized usage without returning content" do
    plug = fn conn ->
      [%{"content" => prompt}] = conn.body_params["messages"] |> Enum.take(-1)
      expected = Jason.decode!(prompt)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "id" => "probe-request-1",
          "model" => "gpt-probe",
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => Jason.encode!(expected)}}
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 8, "total_tokens" => 18}
        })
      )
    end

    assert {:ok, report} = ProviderStaging.probe(provider(plug))
    assert report["status"] == "passed"
    assert report["request_id"] == "probe-request-1"
    assert report["checks"]["usage_accounting"] == "passed"
    refute Map.has_key?(report, "content")
  end

  test "classifies rate limits and rejects mock routes" do
    rate_limited = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(429, Jason.encode!(%{"error" => %{"message" => "slow down"}}))
    end

    assert {:error, report} = ProviderStaging.probe(provider(rate_limited))
    assert report["classification"] == "rate_limit"
    assert report["http_status"] == 429

    assert {:error, unsupported} =
             ProviderStaging.probe(%ProviderConfig{
               name: "Mock",
               kind: "mock",
               model: "mock-v1"
             })

    assert unsupported["classification"] == "unsupported"
  end

  defp provider(plug) do
    %ProviderConfig{
      name: "Staging route",
      kind: "openai_compatible",
      model: "gpt-probe",
      base_url: "http://provider-probe.test",
      api_key_env: "HYDRA_PROVIDER_PROBE_KEY",
      metadata: %{req_options: [plug: plug]}
    }
  end
end
