defmodule HydraAgent.ReleaseConfig do
  @moduledoc "Validated, fail-closed production configuration helpers."

  @unsafe_hosts ~w(example.com localhost localhost.localdomain)

  def required_env!(name) when is_binary(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> raise "environment variable #{name} must not be empty"
          trimmed -> trimmed
        end

      _ ->
        raise "environment variable #{name} is required"
    end
  end

  def secret_env!(name, minimum_bytes) when is_integer(minimum_bytes) and minimum_bytes > 0 do
    secret = required_env!(name)

    if byte_size(secret) < minimum_bytes do
      raise "environment variable #{name} must contain at least #{minimum_bytes} bytes"
    end

    secret
  end

  def public_host_env!(name) do
    host = required_env!(name) |> String.downcase() |> String.trim_trailing(".")

    cond do
      host in @unsafe_hosts ->
        raise "environment variable #{name} must name the public production host"

      String.ends_with?(host, ".localhost") or String.ends_with?(host, ".local") ->
        raise "environment variable #{name} must not use a local-only hostname"

      String.contains?(host, "://") or String.contains?(host, "/") ->
        raise "environment variable #{name} must be a hostname without scheme or path"

      true ->
        host
    end
  end

  def positive_integer_env!(name, default) when is_integer(default) and default > 0 do
    value = System.get_env(name) || Integer.to_string(default)

    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> raise "environment variable #{name} must be a positive integer"
    end
  end

  def boolean_env!(name, default \\ false) when is_boolean(default) do
    case System.get_env(name) do
      nil -> default
      value when value in ~w(true 1) -> true
      value when value in ~w(false 0) -> false
      _ -> raise "environment variable #{name} must be true, false, 1, or 0"
    end
  end

  def enum_env!(name, allowed, default)
      when is_list(allowed) and allowed != [] and is_binary(default) do
    value = System.get_env(name) || default

    if value in allowed do
      value
    else
      raise "environment variable #{name} must be one of #{Enum.join(allowed, ", ")}"
    end
  end
end
