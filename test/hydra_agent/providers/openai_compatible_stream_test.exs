defmodule HydraAgent.Providers.OpenAICompatibleStreamTest do
  use ExUnit.Case

  alias HydraAgent.Providers
  alias HydraAgent.Providers.OpenAICompatible.Stream
  alias HydraAgent.Runtime.ProviderConfig

  test "parser handles split SSE chunks and accumulates content, finish, and usage" do
    provider = %ProviderConfig{name: "openai", kind: "openai_compatible", model: "gpt-test"}
    state = Stream.new(provider)

    chunk1 = """
    data: {"model":"gpt-stream","choices":[{"delta":{"role":"assistant","content":"hel"}}]}

    data: {"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}

    data: {"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}
    """

    {state, events} = Stream.parse_chunk(state, String.slice(chunk1, 0, 120))
    {state, more_events} = Stream.parse_chunk(state, String.slice(chunk1, 120..-1//1) <> "\n")
    {state, final_events} = Stream.finish(state)

    events = events ++ more_events ++ final_events

    assert %{
             "message" => %{"role" => "assistant", "content" => "hello"},
             "model" => "gpt-stream",
             "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5},
             "finish_reason" => "stop"
           } = Stream.response(state, provider)

    assert Enum.map(events, & &1["type"]) == [
             "message.delta",
             "message.delta",
             "message.finish",
             "message.usage"
           ]
  end

  test "parser reports invalid JSON events without raising" do
    provider = %ProviderConfig{name: "openai", kind: "openai_compatible", model: "gpt-test"}

    {_state, events} =
      provider
      |> Stream.new()
      |> Stream.parse_chunk("data: {not-json}\n\n")

    assert [%{"type" => "message.error", "reason" => "invalid_sse_json"}] = events
  end

  test "openai-compatible provider streams via SSE transport" do
    System.put_env("HYDRA_TEST_OPENAI_KEY", "test-key")
    parent = self()

    plug = fn conn ->
      assert ["Bearer test-key"] = Plug.Conn.get_req_header(conn, "authorization")
      assert conn.request_path == "/chat/completions"
      assert conn.body_params["stream"] == true

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          """
          data: {"id":"chatcmpl-test","model":"gpt-test","choices":[{"delta":{"role":"assistant","content":"hyd"}}]}

          data: {"id":"chatcmpl-test","model":"gpt-test","choices":[{"delta":{"content":"ra"},"finish_reason":"stop"}]}

          """
        )

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          """
          data: {"id":"chatcmpl-test","model":"gpt-test","choices":[],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}

          data: [DONE]

          """
        )

      conn
    end

    provider = %ProviderConfig{
      name: "openai",
      kind: "openai_compatible",
      model: "gpt-test",
      base_url: "http://test",
      api_key_env: "HYDRA_TEST_OPENAI_KEY",
      metadata: %{req_options: [plug: plug]}
    }

    assert {:ok, response} =
             Providers.stream_chat(
               provider,
               %{messages: [%{"role" => "user", "content" => "hello"}]},
               fn delta -> send(parent, {:delta, delta}) end
             )

    assert response["message"]["content"] == "hydra"
    assert response["message"]["role"] == "assistant"
    assert response["usage"] == %{"input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6}
    assert response["finish_reason"] == "stop"

    assert_receive {:delta, %{"type" => "message.delta", "content" => "hyd"}}
    assert_receive {:delta, %{"type" => "message.delta", "content" => "ra"}}
    assert_receive {:delta, %{"type" => "message.finish", "finish_reason" => "stop"}}
    assert_receive {:delta, %{"type" => "message.usage", "usage" => %{"total_tokens" => 6}}}
  after
    System.delete_env("HYDRA_TEST_OPENAI_KEY")
  end

  test "openai-compatible stream returns provider errors without creating deltas" do
    System.put_env("HYDRA_TEST_OPENAI_KEY", "test-key")
    parent = self()

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => %{"message" => "bad request"}}))
    end

    provider = %ProviderConfig{
      name: "openai",
      kind: "openai_compatible",
      model: "gpt-test",
      base_url: "http://test",
      api_key_env: "HYDRA_TEST_OPENAI_KEY",
      metadata: %{req_options: [plug: plug]}
    }

    assert {:error, %{"reason" => "provider_http_error", "status" => 400}} =
             Providers.stream_chat(provider, %{messages: []}, fn delta ->
               send(parent, {:delta, delta})
             end)

    refute_receive {:delta, _delta}
  after
    System.delete_env("HYDRA_TEST_OPENAI_KEY")
  end

  test "openai-compatible stream rejects invalid SSE without creating deltas" do
    System.put_env("HYDRA_TEST_OPENAI_KEY", "test-key")
    parent = self()

    plug = fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} = Plug.Conn.chunk(conn, "data: {not-json}\n\n")
      conn
    end

    provider = %ProviderConfig{
      name: "openai",
      kind: "openai_compatible",
      model: "gpt-test",
      base_url: "http://test",
      api_key_env: "HYDRA_TEST_OPENAI_KEY",
      metadata: %{req_options: [plug: plug]}
    }

    assert {:error,
            %{
              "reason" => "invalid_sse_stream",
              "stream_errors" => [%{"reason" => "invalid_sse_json"}]
            }} =
             Providers.stream_chat(provider, %{messages: []}, fn delta ->
               send(parent, {:delta, delta})
             end)

    refute_receive {:delta, _delta}
  after
    System.delete_env("HYDRA_TEST_OPENAI_KEY")
  end
end
