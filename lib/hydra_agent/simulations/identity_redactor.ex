defmodule HydraAgent.Simulations.IdentityRedactor do
  @moduledoc "Deterministic structured-identity and common PII redaction for portable exports."

  @identity_keys MapSet.new(~w(
    address customer_id display_name email employee_id external_id filename first_name
    full_name last_name name person_name phone telephone user_name username
  ))
  @agent_id_keys MapSet.new(~w(agent_id representative_agent_id actor_key))
  @email ~r/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/iu
  # Keep ISO dates intact: they are reproducibility metadata, not phone numbers.
  @phone ~r/(?<!\w)(?!\d{4}-\d{2}-\d{2}(?!\d))(?:\+?\d(?:[\s().\-]*\d){6,14})(?!\w)/u

  def new(values) do
    values = List.wrap(values)

    identities =
      values
      |> Enum.reduce(%{}, &collect(&1, nil, &2))
      |> Enum.reject(fn {value, _kind} -> String.length(value) < 3 end)
      |> Enum.sort_by(fn {value, _kind} -> {-String.length(value), value} end)

    replacements =
      Map.new(identities, fn {value, kind} ->
        replacement =
          cond do
            kind == :agent_id -> "agent-" <> short_hash(value)
            kind == :filename -> redacted_filename(value)
            kind in [:email, :phone, :address] -> "[redacted-#{kind}]"
            true -> "person-" <> short_hash(value)
          end

        {value, replacement}
      end)

    %{replacements: replacements, ordered: identities}
  end

  def redact(value, redactor), do: do_redact(value, nil, redactor)

  defp collect(value, _key, acc) when is_map(value) do
    Enum.reduce(value, acc, fn {nested_key, nested}, current ->
      collect(nested, to_string(nested_key), current)
    end)
  end

  defp collect(values, "imported_agents", acc) when is_list(values) do
    Enum.reduce(values, acc, fn agent, current ->
      current =
        case agent do
          %{"id" => id} when is_binary(id) -> Map.put(current, String.trim(id), :agent_id)
          _ -> current
        end

      collect(agent, "imported_agent", current)
    end)
  end

  defp collect(values, key, acc) when is_list(values),
    do: Enum.reduce(values, acc, &collect(&1, key, &2))

  defp collect(value, key, acc) when is_binary(value) do
    normalized = String.trim(value)

    cond do
      normalized == "" -> acc
      MapSet.member?(@agent_id_keys, key) -> Map.put(acc, normalized, :agent_id)
      MapSet.member?(@identity_keys, key) -> Map.put(acc, normalized, identity_kind(key))
      true -> acc
    end
  end

  defp collect(_value, _key, acc), do: acc

  defp do_redact(value, _key, redactor) when is_map(value) do
    Map.new(value, fn {nested_key, nested} ->
      nested_key = to_string(nested_key)
      {nested_key, do_redact(nested, nested_key, redactor)}
    end)
  end

  defp do_redact(values, key, redactor) when is_list(values),
    do: Enum.map(values, &do_redact(&1, key, redactor))

  defp do_redact(value, key, redactor) when is_binary(value) do
    direct = redactor.replacements[value]

    cond do
      direct ->
        direct

      MapSet.member?(@identity_keys, key) ->
        fallback_identity(value, key)

      key in ["uri", "url"] ->
        redact_uri(value, redactor)

      true ->
        redact_string(value, redactor)
    end
  end

  defp do_redact(value, _key, _redactor), do: value

  defp redact_string(value, redactor) do
    value =
      Enum.reduce(redactor.ordered, value, fn {identity, _kind}, current ->
        String.replace(current, identity, redactor.replacements[identity])
      end)

    value
    |> String.replace(@email, "[redacted-email]")
    |> String.replace(@phone, "[redacted-phone]")
  end

  defp redact_uri(value, redactor) do
    value = redact_string(value, redactor)

    case URI.new(value) do
      {:ok, %URI{} = uri} when is_binary(uri.host) ->
        URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})

      _ ->
        value
    end
  end

  defp fallback_identity(value, "filename"), do: redacted_filename(value)
  defp fallback_identity(_value, "email"), do: "[redacted-email]"
  defp fallback_identity(_value, key) when key in ["phone", "telephone"], do: "[redacted-phone]"
  defp fallback_identity(_value, "address"), do: "[redacted-address]"
  defp fallback_identity(value, _key), do: "person-" <> short_hash(value)

  defp identity_kind("filename"), do: :filename
  defp identity_kind("email"), do: :email
  defp identity_kind(key) when key in ["phone", "telephone"], do: :phone
  defp identity_kind("address"), do: :address
  defp identity_kind(_key), do: :identity

  defp redacted_filename(filename) do
    extension = filename |> Path.extname() |> String.downcase()
    "document-" <> short_hash(filename) <> extension
  end

  defp short_hash(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
