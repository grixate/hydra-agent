defmodule HydraAgent.Simulations.UntrustedText do
  @moduledoc "Fail-closed normalization for source text that must remain inert data."

  @max_chars 20_000
  @active_block ~r/<\s*(script|style|iframe|object|embed)\b[^>]*>.*?<\s*\/\s*\1\s*>/isu
  @active_tag ~r/<\s*\/?\s*(script|style|iframe|object|embed)\b[^>]*>/iu

  @instruction_patterns [
    {"ignore_previous_instructions", ~r/\bignore\s+(all\s+)?previous\s+instructions?\b/iu},
    {"system_prompt_request", ~r/\b(system|developer)\s+(prompt|message|instructions?)\b/iu},
    {"tool_control_request",
     ~r/\b(call|invoke|enable|disable)\s+(a\s+)?(tool|function|plugin)\b/iu},
    {"credential_request", ~r/\b(api\s*key|access\s*token|password|provider\s+credentials?)\b/iu},
    {"policy_override_request",
     ~r/\b(override|bypass|disable)\s+(the\s+)?(policy|safety|budget|schema)\b/iu}
  ]

  def sanitize(value) when is_binary(value) do
    text =
      value
      |> String.replace(<<0>>, "")
      |> String.replace(@active_block, " [active content removed] ")
      |> String.replace(@active_tag, " [active content removed] ")
      |> String.trim()
      |> String.slice(0, @max_chars)

    flags =
      @instruction_patterns
      |> Enum.filter(fn {_flag, pattern} -> Regex.match?(pattern, text) end)
      |> Enum.map(&elem(&1, 0))

    %{
      "text" => text,
      "flags" => flags,
      "review_required" => flags != [],
      "active_content_removed" => String.contains?(text, "[active content removed]")
    }
  end

  def sanitize(_value) do
    %{
      "text" => "",
      "flags" => ["invalid_source_text"],
      "review_required" => true,
      "active_content_removed" => false
    }
  end

  def excerpt(text, max_chars \\ 420)

  def excerpt(text, max_chars) when is_binary(text) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, max_chars)
  end

  def excerpt(_text, _max_chars), do: ""

  def delimit(source_id, text) do
    """
    <untrusted_source id=#{inspect(to_string(source_id))}>
    #{text}
    </untrusted_source>
    """
  end
end
