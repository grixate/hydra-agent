defmodule HydraAgent.ProvidersTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Providers
  alias HydraAgent.Runtime.ProviderConfig

  test "mock provider returns normalized chat responses" do
    provider = %ProviderConfig{name: "mock-fast", kind: "mock", model: "mock-1"}

    assert {:ok, response} =
             Providers.chat(provider, %{
               messages: [%{"role" => "user", "content" => "hello"}]
             })

    assert response["provider"] == "mock-fast"
    assert response["model"] == "mock-1"
    assert response["message"]["role"] == "assistant"
    assert response["message"]["content"] == "mock: hello"
  end

  test "mock provider streams deltas and returns final response" do
    provider = %ProviderConfig{name: "mock-fast", kind: "mock", model: "mock-1"}
    parent = self()

    assert {:ok, response} =
             Providers.stream_chat(
               provider,
               %{messages: [%{"role" => "user", "content" => "stream me"}]},
               fn delta -> send(parent, {:delta, delta}) end
             )

    assert response["message"]["content"] == "mock: stream me"
    assert_receive {:delta, %{"type" => "message.delta", "content" => "mock: stream me"}}
  end

  test "openai-compatible provider fails closed when api key env is absent" do
    provider = %ProviderConfig{
      name: "openai",
      kind: "openai_compatible",
      model: "gpt-test",
      api_key_env: "HYDRA_TEST_MISSING_KEY"
    }

    assert {:error, %{"reason" => "missing_secret_env"}} =
             Providers.chat(provider, %{messages: []})
  end
end
