defmodule HydraAgent.Providers.OpenAICompatible.Stream do
  @moduledoc false

  def new(provider) do
    %{
      buffer: "",
      content: "",
      role: "assistant",
      model: provider.model,
      usage: %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0},
      finish_reason: nil
    }
  end

  def parse_chunk(state, chunk) when is_binary(chunk) do
    buffer = normalize_newlines(state.buffer <> chunk)
    parts = String.split(buffer, "\n\n")
    {complete_blocks, [pending]} = Enum.split(parts, -1)

    {state, events} =
      Enum.reduce(complete_blocks, {%{state | buffer: pending}, []}, fn block, {state, events} ->
        {state, block_events} = parse_block(state, block)
        {state, events ++ block_events}
      end)

    {state, events}
  end

  def finish(state) do
    {state, events} =
      case String.trim(state.buffer || "") do
        "" -> {%{state | buffer: ""}, []}
        _buffer -> parse_block(%{state | buffer: ""}, state.buffer)
      end

    {state, events}
  end

  def response(state, provider) do
    %{
      "provider" => provider.name,
      "model" => state.model || provider.model,
      "message" => %{"role" => state.role || "assistant", "content" => state.content || ""},
      "usage" => state.usage || %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0},
      "finish_reason" => state.finish_reason
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp parse_block(state, block) do
    data =
      block
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(fn "data:" <> data -> String.trim_leading(data) end)
      |> Enum.join("\n")

    parse_data(state, data)
  end

  defp parse_data(state, ""), do: {state, []}
  defp parse_data(state, "[DONE]"), do: {state, []}

  defp parse_data(state, data) do
    case Jason.decode(data) do
      {:ok, chunk} when is_map(chunk) ->
        parse_json_chunk(state, chunk)

      {:error, error} ->
        {state,
         [
           %{
             "type" => "message.error",
             "reason" => "invalid_sse_json",
             "error" => Exception.message(error)
           }
         ]}
    end
  end

  defp parse_json_chunk(state, chunk) do
    choices = List.wrap(chunk["choices"] || [])
    state = %{state | model: chunk["model"] || state.model}

    {state, events} =
      Enum.reduce(choices, {state, []}, fn choice, {state, events} ->
        parse_choice(state, choice, events)
      end)

    case normalize_usage(chunk["usage"] || %{}) do
      %{"total_tokens" => total} = usage when total > 0 ->
        {%{state | usage: usage}, events ++ [%{"type" => "message.usage", "usage" => usage}]}

      _usage ->
        {state, events}
    end
  end

  defp parse_choice(state, choice, events) do
    delta = choice["delta"] || %{}

    state =
      case delta["role"] do
        role when is_binary(role) -> %{state | role: role}
        _role -> state
      end

    content = delta["content"] || ""
    tool_calls = delta["tool_calls"] || []
    finish_reason = choice["finish_reason"]

    state =
      if is_binary(content) and content != "",
        do: %{state | content: state.content <> content},
        else: state

    events =
      if is_binary(content) and content != "",
        do: events ++ [%{"type" => "message.delta", "content" => content}],
        else: events

    events =
      if tool_calls != [] do
        events ++ [%{"type" => "tool_call.delta", "tool_calls" => tool_calls}]
      else
        events
      end

    if is_binary(finish_reason) do
      {%{state | finish_reason: finish_reason},
       events ++ [%{"type" => "message.finish", "finish_reason" => finish_reason}]}
    else
      {state, events}
    end
  end

  defp normalize_usage(usage) when is_map(usage) do
    %{
      "input_tokens" => usage["prompt_tokens"] || usage["input_tokens"] || 0,
      "output_tokens" => usage["completion_tokens"] || usage["output_tokens"] || 0,
      "total_tokens" => usage["total_tokens"] || 0
    }
  end

  defp normalize_newlines(value) do
    value
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end
end
