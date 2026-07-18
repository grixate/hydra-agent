defmodule HydraAgent.Simulations.PriceRegistry do
  @moduledoc "Immutable, effective-dated provider pricing and run-safe price snapshots."

  import Ecto.Query

  alias Decimal, as: D
  alias HydraAgent.Repo
  alias HydraAgent.Simulations.PriceEntry

  @million D.new(1_000_000)

  def create_entry(attrs) do
    %PriceEntry{}
    |> PriceEntry.changeset(attrs)
    |> Repo.insert()
  end

  def list_entries(workspace_id, at \\ DateTime.utc_now()) do
    PriceEntry
    |> where(
      [entry],
      (is_nil(entry.workspace_id) or entry.workspace_id == ^workspace_id) and
        entry.effective_from <= ^at
    )
    |> order_by([entry],
      asc: entry.provider,
      asc: entry.model,
      desc: fragment("? IS NOT NULL", entry.workspace_id),
      desc: entry.effective_from,
      desc: entry.id
    )
    |> Repo.all()
  end

  def snapshot(workspace_id, resolved_routes, captured_at \\ DateTime.utc_now()) do
    entries = list_entries(workspace_id, captured_at)

    routes =
      Map.new(resolved_routes, fn {role, route} ->
        {role, price_for_route(route, entries)}
      end)
      |> Map.put(
        "retrieval",
        price_for_route(
          %{
            "status" => "resolved",
            "provider" => "web_search",
            "model" => "request",
            "local" => false,
            "route_version" => "web-search/v1"
          },
          entries
        )
      )

    {currency, currency_status} = snapshot_currency(routes)

    %{
      "captured_at" => DateTime.to_iso8601(captured_at),
      "currency" => currency,
      "currency_status" => currency_status,
      "entries" => routes
    }
  end

  def estimate_max(%{"pricing" => "known"} = price, input_tokens, output_tokens)
      when is_integer(input_tokens) and input_tokens >= 0 and is_integer(output_tokens) and
             output_tokens >= 0 do
    input = D.mult(D.new(input_tokens), decimal(price["input_per_million"])) |> D.div(@million)
    output = D.mult(D.new(output_tokens), decimal(price["output_per_million"])) |> D.div(@million)
    minimum = decimal(price["request_minimum"] || "0")
    total = D.add(input, output)
    if D.compare(total, minimum) == :lt, do: minimum, else: total
  end

  def estimate_max(_price, _input_tokens, _output_tokens), do: nil

  def estimate_stage_max(price, input_tokens, output_tokens, calls)
      when is_integer(calls) and calls >= 0 do
    with %D{} = token_cost <- estimate_max(price, input_tokens, output_tokens) do
      request_floor = D.mult(decimal(price["request_minimum"] || "0"), D.new(calls))
      if D.compare(token_cost, request_floor) == :lt, do: request_floor, else: token_cost
    end
  end

  defp price_for_route(%{"status" => "disabled"} = route, _entries) do
    base_price(route, "not_applicable")
    |> Map.merge(%{
      "currency" => "USD",
      "input_per_million" => "0",
      "cached_input_per_million" => "0",
      "output_per_million" => "0",
      "request_minimum" => "0",
      "source" => "disabled_route"
    })
  end

  defp price_for_route(%{"status" => "resolved", "local" => true} = route, _entries) do
    base_price(route, "known")
    |> Map.merge(%{
      "currency" => "USD",
      "input_per_million" => "0",
      "cached_input_per_million" => "0",
      "output_per_million" => "0",
      "request_minimum" => "0",
      "source" => "local_route"
    })
  end

  defp price_for_route(%{"status" => "resolved"} = route, entries) do
    case Enum.find(entries, &matches?(&1, route)) do
      nil ->
        base_price(route, "unknown")

      entry ->
        base_price(route, "known")
        |> Map.merge(%{
          "price_entry_id" => entry.id,
          "currency" => entry.currency,
          "input_per_million" => decimal_string(entry.input_per_million),
          "cached_input_per_million" => decimal_string(entry.cached_input_per_million),
          "output_per_million" => decimal_string(entry.output_per_million),
          "request_minimum" => decimal_string(entry.request_minimum || D.new(0)),
          "effective_from" => DateTime.to_iso8601(entry.effective_from),
          "operator_override" => entry.operator_override,
          "source" => if(entry.workspace_id, do: "workspace_override", else: "registry")
        })
    end
  end

  defp price_for_route(route, _entries), do: base_price(route, "unknown")

  defp base_price(route, pricing) do
    %{
      "pricing" => pricing,
      "provider" => route["provider"],
      "model" => route["model"],
      "route_version" => route["route_version"]
    }
  end

  defp matches?(entry, route),
    do: entry.provider == route["provider"] and entry.model == route["model"]

  defp snapshot_currency(routes) do
    currencies =
      routes
      |> Map.values()
      |> Enum.filter(&billable_price?/1)
      |> Enum.map(& &1["currency"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case currencies do
      [] -> {"USD", "single"}
      [currency] -> {currency, "single"}
      _other -> {"USD", "mixed"}
    end
  end

  defp billable_price?(%{"pricing" => "known"} = price) do
    Enum.any?(
      ~w(input_per_million cached_input_per_million output_per_million request_minimum),
      fn
        field ->
          case D.cast(price[field]) do
            {:ok, value} -> D.compare(value, 0) == :gt
            :error -> false
          end
      end
    )
  end

  defp billable_price?(_price), do: false

  defp decimal(nil), do: D.new(0)
  defp decimal(%D{} = value), do: value
  defp decimal(value), do: D.new(value)

  defp decimal_string(nil), do: nil
  defp decimal_string(%D{} = value), do: D.to_string(value, :normal)
end
