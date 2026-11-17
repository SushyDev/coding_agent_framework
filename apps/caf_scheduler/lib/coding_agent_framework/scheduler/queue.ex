defmodule CodingAgentFramework.Scheduler.Queue do
  @moduledoc """
  The order in which waiting requests are granted (`model/tla/Schedule.tla`'s `Insert`): a
  pure module over the `Scheduler`'s queue, which is in memory.

  - **Classes**, four and fixed, in this order: `:main` (a person's main session), `:landing`
    (a landing's gates), `:builder`, `:heavy`. A class is served only when no waiting request
    of a higher class can be granted.
  - **The hold.** A grant takes no unit a waiting request of a higher class needs: the units
    those requests need are reserved beside the held ones, so a waiting landing holds the next
    free unit of each resource it needs.
  - **Inside a class**, a request that has waited `age` ms or more goes first, oldest first
    (aging reorders only inside its class, so it never passes the next class); otherwise the
    modules take turns, from the one after the module served last, and one module's requests go
    in the order they came.

      iex> alias CodingAgentFramework.Scheduler.Queue
      iex> landing = %{seq: 1, asked_at: 0, req: %{class: :landing, module: "m", units: %{"slot" => 1, "lock" => 1}}}
      iex> heavy = %{seq: 2, asked_at: 0, req: %{class: :heavy, module: "n", units: %{"slot" => 1}}}
      iex> cap = %{"slot" => 2, "lock" => 1}
      iex> # The lock is held: the landing waits, and holds the free slot from the heavy run.
      iex> Queue.next([landing, heavy], %{}, %{"slot" => 1, "lock" => 1}, cap, fn _ -> true end, 0, nil)
      :none
      iex> {:grant, ^heavy, _} = Queue.next([heavy], %{}, %{"slot" => 1, "lock" => 1}, cap, fn _ -> true end, 0, nil)
  """

  @classes [:main, :landing, :builder, :heavy]

  @type entry :: %{seq: integer, asked_at: integer, req: map}

  @doc "The classes, highest first."
  @spec classes() :: [atom]
  def classes, do: @classes

  @doc """
  The next request to grant, `{:grant, entry, reserved}` with the units its higher classes
  hold, or `:none`. `held` is what the unreleased leases hold, `capacity` each resource's,
  `admitted?` the gates' word on an entry, `rot` the module each class served last, and `age`
  the wait (ms) after which a request goes first in its class, or nil for none.
  """
  @spec next([entry], map, map, map, (entry -> boolean), integer, integer | nil) ::
          {:grant, entry, map} | :none
  def next(entries, rot, held, capacity, admitted?, now, age) do
    Enum.reduce_while(@classes, :none, fn class, :none ->
      reserved = reserved(entries, class)

      fit =
        for %{req: %{class: ^class}} = e <- entries,
            fits?(e.req.units, held, reserved, capacity),
            admitted?.(e),
            do: e

      case pick(fit, rot[class], now, age) do
        nil -> {:cont, :none}
        e -> {:halt, {:grant, e, reserved}}
      end
    end)
  end

  @doc """
  The units the waiting requests of a class higher than `class` need.

      iex> e = %{req: %{class: :landing, units: %{"slot" => 1}}}
      iex> CodingAgentFramework.Scheduler.Queue.reserved([e, e], :heavy)
      %{"slot" => 2}
  """
  @spec reserved([entry], atom) :: map
  def reserved(entries, class) do
    for %{req: req} <- entries, rank(req.class) < rank(class), {r, n} <- req.units, reduce: %{} do
      acc -> Map.update(acc, r, n, &(&1 + n))
    end
  end

  @doc "Whether `units` fit beside `held` and `reserved` within `capacity`."
  @spec fits?(map, map, map, map) :: boolean
  def fits?(units, held, reserved, capacity) do
    Enum.all?(units, fn {r, n} ->
      Map.get(held, r, 0) + Map.get(reserved, r, 0) + n <= Map.get(capacity, r, 0)
    end)
  end

  @doc "A class's rank, 1 the highest."
  @spec rank(atom) :: pos_integer
  def rank(class), do: Enum.find_index(@classes, &(&1 == class)) + 1

  @doc """
  An entry's place among its class's waiting requests, 1 the first, as `next/7` would order
  them were they all to fit now.
  """
  @spec position([entry], entry, map, integer, integer | nil) :: pos_integer
  def position(entries, entry, rot, now, age) do
    same = Enum.filter(entries, &(&1.req.class == entry.req.class))

    Stream.unfold({same, rot[entry.req.class]}, fn
      {[], _} ->
        nil

      {left, last} ->
        e = pick(left, last, now, age)
        {e, {List.delete(left, e), e.req.module}}
    end)
    |> Enum.find_index(&(&1.seq == entry.seq))
    |> Kernel.+(1)
  end

  defp pick([], _last, _now, _age), do: nil

  defp pick(fit, last, now, age) do
    aged = if age, do: Enum.filter(fit, &(now - &1.asked_at >= age)), else: []

    case aged do
      [] ->
        modules = fit |> Enum.map(& &1.req.module) |> Enum.uniq() |> Enum.sort()
        module = Enum.find(modules, hd(modules), &(last == nil or &1 > last))
        fit |> Enum.filter(&(&1.req.module == module)) |> Enum.min_by(& &1.seq)

      aged ->
        Enum.min_by(aged, &{&1.asked_at, &1.seq})
    end
  end
end
