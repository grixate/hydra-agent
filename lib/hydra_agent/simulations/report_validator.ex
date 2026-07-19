defmodule HydraAgent.Simulations.ReportValidator do
  @moduledoc "Strictly validates model-derived Reports against an immutable Analysis Pack."

  alias HydraAgent.Simulations.AnalysisPack

  @top_keys MapSet.new(~w(title summary sections limitations recommended_next_steps))
  @section_keys MapSet.new(~w(heading body references))
  @section_count 9
  @number_regex ~r/(?<![\p{L}\p{N}_])-?\d+(?:[.,]\d+)?%?(?![\p{L}\p{N}_])/u
  @url_regex ~r/https?:\/\/[^\s)\]}]+/iu
  @quote_regex ~r/[“”"]([^“”"]{2,})[“”"]/u

  def validate(%AnalysisPack{} = pack, payload), do: validate(pack.reference_index, payload)

  def validate(reference_index, payload) when is_map(reference_index) and is_map(payload) do
    errors =
      []
      |> exact_keys(payload, @top_keys, "report")
      |> required_text(payload, "title", 1, 180)
      |> required_text(payload, "summary", 1, 1_500)
      |> string_list(payload, "limitations", 12, 1_000)
      |> string_list(payload, "recommended_next_steps", 12, 1_000)
      |> validate_sections(payload["sections"], reference_index)
      |> validate_unreferenced_prose(payload)

    if errors == [], do: {:ok, normalize(payload)}, else: {:error, Enum.reverse(errors)}
  end

  def validate(_reference_index, _payload),
    do: {:error, [error("report", "invalid_type", "must be an object")]}

  defp validate_sections(errors, sections, reference_index)
       when is_list(sections) and length(sections) == @section_count do
    sections
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {section, index}, acc ->
      path = "sections[#{index}]"

      if is_map(section) do
        references = section["references"]

        acc
        |> exact_keys(section, @section_keys, path)
        |> required_text(section, "heading", 1, 140, path)
        |> required_text(section, "body", 1, 4_000, path)
        |> references(references, reference_index, path)
        |> grounded_numbers(section["body"], references, reference_index, path)
        |> grounded_quotes(section["body"], references, path)
        |> no_urls(section["body"], path)
      else
        [error(path, "invalid_type", "must be an object") | acc]
      end
    end)
  end

  defp validate_sections(errors, _sections, _reference_index) do
    [
      error("sections", "invalid_count", "must contain exactly #{@section_count} sections")
      | errors
    ]
  end

  defp exact_keys(errors, value, expected, path) do
    actual = value |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()

    if MapSet.equal?(actual, expected) do
      errors
    else
      [
        error(
          path,
          "unexpected_keys",
          "must contain only #{expected |> Enum.sort() |> Enum.join(", ")}"
        )
        | errors
      ]
    end
  end

  defp required_text(errors, map, field, minimum, maximum, prefix \\ nil) do
    value = map[field]
    path = if(prefix, do: "#{prefix}.#{field}", else: field)

    if is_binary(value) and String.length(String.trim(value)) in minimum..maximum,
      do: errors,
      else: [error(path, "invalid_text", "must be #{minimum}–#{maximum} characters") | errors]
  end

  defp string_list(errors, map, field, maximum_items, maximum_length) do
    value = map[field]

    valid =
      is_list(value) and length(value) <= maximum_items and
        Enum.all?(value, &(is_binary(&1) and String.length(String.trim(&1)) in 1..maximum_length))

    if valid,
      do: errors,
      else: [error(field, "invalid_list", "must be a bounded list of non-empty strings") | errors]
  end

  defp references(errors, refs, reference_index, path)
       when is_list(refs) and length(refs) in 1..12 do
    invalid = Enum.reject(refs, &(is_binary(&1) and Map.has_key?(reference_index, &1)))

    if invalid == [],
      do: errors,
      else: [error("#{path}.references", "unknown_reference", inspect(invalid)) | errors]
  end

  defp references(errors, _refs, _reference_index, path) do
    [
      error("#{path}.references", "invalid_references", "must contain 1–12 known references")
      | errors
    ]
  end

  defp grounded_numbers(errors, body, references, reference_index, path)
       when is_binary(body) and is_list(references) do
    allowed =
      references
      |> Enum.flat_map(fn ref -> get_in(reference_index, [ref, "numeric_values"]) || [] end)
      |> Enum.map(&canonical_number/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    unsupported =
      @number_regex
      |> Regex.scan(body, capture: :first)
      |> List.flatten()
      |> Enum.reject(&MapSet.member?(allowed, canonical_number(&1)))
      |> Enum.uniq()

    if unsupported == [],
      do: errors,
      else: [error("#{path}.body", "unsupported_number", inspect(unsupported)) | errors]
  end

  defp grounded_numbers(errors, _body, _references, _reference_index, _path), do: errors

  defp grounded_quotes(errors, body, references, path)
       when is_binary(body) and is_list(references) do
    has_quote = Regex.match?(@quote_regex, body)
    has_trace = Enum.any?(references, &String.starts_with?(&1, ["decision:", "trace:"]))

    if has_quote and not has_trace,
      do: [
        error("#{path}.body", "unsupported_quote", "quotes require a decision or trace reference")
        | errors
      ],
      else: errors
  end

  defp grounded_quotes(errors, _body, _references, _path), do: errors

  defp no_urls(errors, body, path) when is_binary(body) do
    if Regex.match?(@url_regex, body),
      do: [
        error("#{path}.body", "invented_url", "URLs must not be generated in report prose")
        | errors
      ],
      else: errors
  end

  defp no_urls(errors, _body, _path), do: errors

  defp validate_unreferenced_prose(errors, payload) do
    ["title", "summary"]
    |> Enum.reduce(errors, fn field, acc ->
      acc
      |> no_numbers(payload[field], field)
      |> no_urls(payload[field], field)
    end)
    |> no_numbers_in_list(payload["limitations"], "limitations")
    |> no_numbers_in_list(payload["recommended_next_steps"], "recommended_next_steps")
  end

  defp no_numbers(errors, value, path) when is_binary(value) do
    if Regex.match?(@number_regex, value),
      do: [
        error(
          path,
          "unreferenced_number",
          "numbers are allowed only in referenced section bodies"
        )
        | errors
      ],
      else: errors
  end

  defp no_numbers(errors, _value, _path), do: errors

  defp no_numbers_in_list(errors, values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {value, index}, acc ->
      acc
      |> no_numbers(value, "#{path}[#{index}]")
      |> no_urls(value, "#{path}[#{index}]")
    end)
  end

  defp no_numbers_in_list(errors, _values, _path), do: errors

  defp canonical_number(value) when is_number(value), do: canonical_number(to_string(value))

  defp canonical_number(value) when is_binary(value) do
    percent? = String.ends_with?(value, "%")

    value =
      value
      |> String.trim()
      |> String.trim_trailing("%")
      |> String.replace(",", ".")

    case Float.parse(value) do
      {number, ""} -> {Float.round(number, 6), percent?}
      _other -> nil
    end
  end

  defp canonical_number(_value), do: nil

  defp normalize(payload) do
    %{
      "title" => String.trim(payload["title"]),
      "summary" => String.trim(payload["summary"]),
      "sections" =>
        Enum.map(payload["sections"], fn section ->
          %{
            "heading" => String.trim(section["heading"]),
            "body" => String.trim(section["body"]),
            "references" => Enum.uniq(section["references"])
          }
        end),
      "limitations" => Enum.map(payload["limitations"], &String.trim/1),
      "recommended_next_steps" => Enum.map(payload["recommended_next_steps"], &String.trim/1)
    }
  end

  defp error(path, code, detail), do: %{"path" => path, "code" => code, "detail" => detail}
end
