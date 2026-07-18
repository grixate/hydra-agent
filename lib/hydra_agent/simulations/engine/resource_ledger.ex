defmodule HydraAgent.Simulations.Engine.ResourceLedger do
  @moduledoc """
  Decimal-backed authoritative balances for one active simulation run.

  Transactions are applied as a stable batch. A failed invariant rejects the
  entire batch, and repeated idempotency keys never change a balance twice.
  """

  use GenServer

  alias Decimal, as: D

  def start_link(opts) do
    run_record_id = Keyword.fetch!(opts, :run_record_id)
    GenServer.start_link(__MODULE__, opts, name: name(run_record_id))
  end

  def name(run_record_id),
    do:
      {:via, Registry, {HydraAgent.ProcessRegistry, {:simulation_resource_ledger, run_record_id}}}

  def load(run_record_id, definitions, agents, world_resources \\ %{}) do
    GenServer.call(name(run_record_id), {:load, definitions, agents, world_resources}, :infinity)
  end

  def restore(run_record_id, definitions, balances) do
    GenServer.call(name(run_record_id), {:restore, definitions, balances}, :infinity)
  end

  def apply_batch(run_record_id, transactions) do
    GenServer.call(name(run_record_id), {:apply_batch, transactions}, :infinity)
  end

  def balances(run_record_id), do: GenServer.call(name(run_record_id), :balances, :infinity)

  def hydrate_agents(run_record_id, agents) do
    GenServer.call(name(run_record_id), {:hydrate_agents, agents}, :infinity)
  end

  def resource_sum(run_record_id, resource_id) do
    GenServer.call(name(run_record_id), {:resource_sum, resource_id}, :infinity)
  end

  @doc false
  def new_state(definitions, balances \\ %{}) do
    %{
      definitions: normalize_definitions(definitions),
      balances: normalize_balances(balances),
      seen: MapSet.new()
    }
  end

  @doc false
  def apply_transactions(state, transactions) do
    transactions
    |> Enum.sort_by(&{Map.get(&1, :order_key) || Map.get(&1, "order_key") || "", idem(&1)})
    |> Enum.reduce_while({:ok, [], state}, fn transaction, {:ok, applied, current} ->
      key = idem(transaction)

      cond do
        not is_binary(key) or key == "" ->
          {:halt, {:error, :missing_idempotency_key}}

        MapSet.member?(current.seen, key) ->
          {:cont, {:ok, applied, current}}

        true ->
          case apply_transaction(current, transaction) do
            {:ok, persisted, next} -> {:cont, {:ok, [persisted | applied], next}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, applied, next} -> {:ok, Enum.reverse(applied), next}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(_opts), do: {:ok, new_state([])}

  @impl true
  def handle_call({:load, definitions, agents, world_resources}, _from, _state) do
    balances =
      agents
      |> Enum.reduce(%{}, fn agent, acc ->
        account = agent_account(agent["id"])
        put_account_resources(acc, account, agent["resources"] || %{})
      end)
      |> put_account_resources("world", world_resources)

    state = new_state(definitions, balances)
    {:reply, :ok, state}
  end

  def handle_call({:restore, definitions, balances}, _from, _state) do
    state = new_state(definitions, balances)
    {:reply, :ok, state}
  end

  def handle_call({:apply_batch, transactions}, _from, state) do
    case apply_transactions(state, transactions) do
      {:ok, applied, next} -> {:reply, {:ok, applied}, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:balances, _from, state), do: {:reply, external_balances(state.balances), state}

  def handle_call({:hydrate_agents, agents}, _from, state) do
    hydrated =
      Enum.map(agents, fn agent ->
        account = agent_account(agent["id"])
        resources = account_balances(state.balances, account, state.definitions)
        Map.put(agent, "resources", resources)
      end)

    {:reply, hydrated, state}
  end

  def handle_call({:resource_sum, resource_id}, _from, state) do
    total =
      state.balances
      |> Enum.filter(fn {{account, resource}, _balance} ->
        String.starts_with?(account, "agent:") and resource == resource_id
      end)
      |> Enum.reduce(D.new(0), fn {_key, balance}, total -> D.add(total, balance) end)
      |> decimal_string()

    {:reply, total, state}
  end

  defp apply_transaction(state, transaction) do
    operation = value(transaction, :operation)
    resource = value(transaction, :resource_id)
    source = value(transaction, :source_account)
    destination = value(transaction, :destination_account)
    signed_amount = decimal(value(transaction, :amount))

    with {:ok, definition} <- fetch_definition(state, resource),
         {:ok, amount, source, destination, direction_tag} <-
           normalize_operation(operation, signed_amount, source, destination),
         amount <- D.round(amount, definition.precision),
         :ok <- validate_operation(definition, operation, source, destination),
         {:ok, balances} <-
           apply_operation(state.balances, operation, source, destination, resource, amount),
         balances <-
           round_touched_balances(balances, definition, resource, [source, destination]),
         :ok <- validate_touched_balances(balances, definition, resource, [source, destination]) do
      balances_map = %{
        "source" => balance_string(balances, source, resource),
        "destination" => balance_string(balances, destination, resource)
      }

      persisted =
        transaction
        |> stringify_transaction()
        |> Map.put("amount", decimal_string(amount))
        |> Map.put("source_account", source)
        |> Map.put("destination_account", destination)
        |> Map.put("resulting_balances", balances_map)
        |> Map.update("tags", direction_tag, fn tags ->
          Enum.uniq(List.wrap(tags) ++ direction_tag)
        end)

      {:ok, persisted,
       %{state | balances: balances, seen: MapSet.put(state.seen, idem(transaction))}}
    end
  rescue
    D.Error -> {:error, :invalid_amount}
  end

  defp normalize_operation("adjust", amount, source, destination) do
    cond do
      D.negative?(amount) -> {:ok, D.abs(amount), source || destination, nil, ["direction:debit"]}
      true -> {:ok, amount, nil, destination || source, ["direction:credit"]}
    end
  end

  defp normalize_operation(operation, amount, _source, destination)
       when operation in ~w(mint replenish),
       do: {:ok, D.abs(amount), nil, destination, []}

  defp normalize_operation(operation, amount, source, _destination)
       when operation in ~w(burn consume),
       do: {:ok, D.abs(amount), source, nil, []}

  defp normalize_operation("transfer", amount, source, destination),
    do: {:ok, D.abs(amount), source, destination, []}

  defp normalize_operation("reserve", amount, source, destination),
    do: {:ok, D.abs(amount), source, destination || "reserved:#{source}", []}

  defp normalize_operation("release", amount, source, destination),
    do: {:ok, D.abs(amount), source, destination, []}

  defp normalize_operation(_operation, _amount, _source, _destination),
    do: {:error, :unsupported_operation}

  defp validate_operation(definition, operation, source, destination) do
    cond do
      operation in ~w(mint replenish) and not definition.mint_allowed ->
        {:error, :mint_not_allowed}

      operation in ~w(burn consume) and not definition.burn_allowed ->
        {:error, :burn_not_allowed}

      operation == "adjust" and is_nil(source) and is_binary(destination) and
          not definition.mint_allowed ->
        {:error, :mint_not_allowed}

      operation == "adjust" and is_binary(source) and is_nil(destination) and
          not definition.burn_allowed ->
        {:error, :burn_not_allowed}

      true ->
        :ok
    end
  end

  defp apply_operation(balances, operation, source, destination, resource, amount)
       when operation in ~w(transfer reserve release) do
    with :ok <- require_account(source),
         :ok <- require_account(destination) do
      {:ok,
       balances
       |> update_balance(source, resource, &D.sub(&1, amount))
       |> update_balance(destination, resource, &D.add(&1, amount))}
    end
  end

  defp apply_operation(balances, operation, _source, destination, resource, amount)
       when operation in ~w(mint replenish) do
    with :ok <- require_account(destination) do
      {:ok, update_balance(balances, destination, resource, &D.add(&1, amount))}
    end
  end

  defp apply_operation(balances, operation, source, _destination, resource, amount)
       when operation in ~w(burn consume) do
    with :ok <- require_account(source) do
      {:ok, update_balance(balances, source, resource, &D.sub(&1, amount))}
    end
  end

  defp apply_operation(balances, "adjust", source, nil, resource, amount) do
    with :ok <- require_account(source) do
      {:ok, update_balance(balances, source, resource, &D.sub(&1, amount))}
    end
  end

  defp apply_operation(balances, "adjust", nil, destination, resource, amount) do
    with :ok <- require_account(destination) do
      {:ok, update_balance(balances, destination, resource, &D.add(&1, amount))}
    end
  end

  defp apply_operation(_balances, _operation, _source, _destination, _resource, _amount),
    do: {:error, :invalid_accounts}

  defp validate_touched_balances(balances, definition, resource, accounts) do
    accounts
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn account, :ok ->
      balance = Map.get(balances, {account, resource}, D.new(0))

      cond do
        not definition.allow_negative and D.negative?(balance) ->
          {:halt, {:error, {:negative_balance, account, resource}}}

        definition.min && D.compare(balance, definition.min) == :lt ->
          {:halt, {:error, {:below_minimum, account, resource}}}

        definition.max && D.compare(balance, definition.max) == :gt ->
          {:halt, {:error, {:above_maximum, account, resource}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp round_touched_balances(balances, definition, resource, accounts) do
    accounts
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce(balances, fn account, current ->
      Map.update(current, {account, resource}, D.new(0), &D.round(&1, definition.precision))
    end)
  end

  defp fetch_definition(state, resource) do
    case state.definitions[resource] do
      nil -> {:error, {:unknown_resource, resource}}
      definition -> {:ok, definition}
    end
  end

  defp normalize_definitions(definitions) do
    Map.new(definitions, fn definition ->
      constraints = definition["constraints"] || %{}
      min_value = constraints["min"]
      max_value = constraints["max"]

      {definition["id"],
       %{
         precision: definition["precision"] || 0,
         min: optional_decimal(min_value),
         max: optional_decimal(max_value),
         allow_negative: definition["allow_negative"] == true or negative?(min_value),
         mint_allowed: Map.get(definition, "mint_allowed", true),
         burn_allowed: Map.get(definition, "burn_allowed", true)
       }}
    end)
  end

  defp normalize_balances(balances) do
    Enum.reduce(balances, %{}, fn
      {{account, resource}, balance}, acc ->
        Map.put(acc, {account, resource}, decimal(balance))

      {account, resources}, acc when is_map(resources) and not is_struct(resources) ->
        put_account_resources(acc, account, resources)
    end)
  end

  defp put_account_resources(balances, account, resources) do
    Enum.reduce(resources || %{}, balances, fn {resource, balance}, acc ->
      Map.put(acc, {account, resource}, decimal(balance))
    end)
  end

  defp external_balances(balances) do
    Enum.reduce(balances, %{}, fn {{account, resource}, balance}, acc ->
      put_in(acc, [Access.key(account, %{}), resource], decimal_string(balance))
    end)
  end

  defp account_balances(balances, account, definitions) do
    Enum.reduce(definitions, %{}, fn {resource, _definition}, resources ->
      case Map.fetch(balances, {account, resource}) do
        {:ok, balance} -> Map.put(resources, resource, decimal_string(balance))
        :error -> resources
      end
    end)
  end

  defp update_balance(balances, account, resource, update) do
    Map.update(balances, {account, resource}, update.(D.new(0)), update)
  end

  defp balance_string(_balances, nil, _resource), do: nil

  defp balance_string(balances, account, resource),
    do: balances |> Map.get({account, resource}, D.new(0)) |> decimal_string()

  defp decimal_string(decimal), do: D.to_string(decimal, :normal)
  defp decimal(%D{} = value), do: value
  defp decimal(value) when is_integer(value), do: D.new(value)
  defp decimal(value) when is_float(value), do: D.from_float(value)
  defp decimal(value) when is_binary(value), do: D.new(value)
  defp decimal(nil), do: D.new(0)

  defp optional_decimal(nil), do: nil
  defp optional_decimal(value), do: decimal(value)
  defp negative?(value) when is_number(value), do: value < 0
  defp negative?(_value), do: false

  defp require_account(account) when is_binary(account) and account != "", do: :ok
  defp require_account(_account), do: {:error, :missing_account}

  defp idem(transaction), do: value(transaction, :idempotency_key)

  defp stringify_transaction(transaction) do
    Map.new(transaction, fn {key, value} -> {to_string(key), value} end)
    |> Map.drop(["order_key"])
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp agent_account(agent_id), do: "agent:#{agent_id}"
end
