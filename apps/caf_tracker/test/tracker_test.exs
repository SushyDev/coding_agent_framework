defmodule CodingAgentFramework.TrackerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CodingAgentFramework.{Registry, TestHost, Tracker}
  alias CodingAgentFramework.Registry.Table
  alias CodingAgentFramework.Tracker.{Fold, ReaderSource}
  alias Exqlite.Sqlite3

  doctest Tracker
  doctest Fold

  # Two accounts written in one file, and one never read, which stays :unread.
  @written [{"h", "a"}, {"h", "b"}]
  @scopes @written ++ [{"h", "never"}]

  defp clock do
    ref = :atomics.new(1, [])
    {ref, fn -> :atomics.get(ref, 1) end}
  end

  defp sources(db),
    do: for({h, a} <- @scopes, do: {ReaderSource, table: Table, db: db, host: h, account: a})

  defp start(db, clock, notify \\ fn _ -> :ok end) do
    {:ok, t} =
      Tracker.start_link(sources: sources(db), clock: clock, notify: notify, timer: false)

    t
  end

  # The writer's step, as `Registry` takes it: one transaction, then a cue naming the ids.
  defp write(db, {h, a}, changes, at) do
    {:ok, %{ids: ids, first: first}} =
      Table.write(db, h, a, changes, %{read_at: at, files: 0, problems: 0})

    if ids != [] or first, do: [%{topic: "registry:#{h}:#{a}", ids: ids}], else: []
  end

  # A row no writer of ours writes: wrong types, bytes that are not text, broken JSON.
  defp malformed(db, {h, a}, n) do
    sql = """
    INSERT INTO registry_sessions (host, account, file, pid, session_id, name, updated_at, extra,
      alive, written_at) VALUES (?1, ?2, ?3, 'seven', 7, X'00ff', 'yesterday', 'not json', 'zzz', 0)
    ON CONFLICT (host, account, file) DO UPDATE SET pid = excluded.pid RETURNING id
    """

    {:ok, stmt} = Sqlite3.prepare(db, sql)
    :ok = Sqlite3.bind(stmt, [h, a, "m#{n}.json"])
    {:ok, [[id]]} = Sqlite3.fetch_all(db, stmt)
    :ok = Sqlite3.release(db, stmt)
    [%{topic: "registry:#{h}:#{a}", ids: [id]}]
  end

  # The fold of the tables' current rows, read in full.
  defp reference(db, now) do
    sources(db)
    |> Enum.reduce(Fold.new(), fn {mod, opts}, fold ->
      d = mod.describe(opts)
      {:ok, source} = mod.open(opts)
      fold = Fold.source(fold, d.topic, d.scope, d.kind)
      {fold, _} = Fold.read(fold, d.topic, :all, mod.read(source, :all))
      fold
    end)
    |> Fold.view(now)
  end

  defp row do
    fixed_map(%{
      pid: one_of([constant(nil), integer(1..99)]),
      session_id: string(:alphanumeric, max_length: 6),
      name: one_of([constant(nil), string(:printable, max_length: 6)]),
      status: member_of([nil, "busy", "idle"]),
      updated_at: one_of([constant(nil), integer(0..100)]),
      alive: member_of([:live, :replaced, :gone, :unknown]),
      problem: member_of([nil, ":not_json"])
    })
  end

  defp event do
    one_of([
      tuple(
        {constant(:write), member_of(@written),
         list_of(tuple({integer(1..5), one_of([constant(:delete), row()])}), max_length: 4)}
      ),
      tuple({constant(:malformed), member_of(@written), integer(1..3)}),
      tuple({constant(:deliver), integer(0..30), boolean()}),
      tuple(
        {constant(:bogus),
         one_of([
           map(list_of(integer(1..60), max_length: 4), &%{topic: "registry:h:a", ids: &1}),
           constant(%{topic: "registry:h:b", ids: ["x"]}),
           constant(%{topic: "registry:h:b"}),
           constant(%{topic: "elsewhere", ids: [1]}),
           constant(:junk)
         ])}
      ),
      constant(:restart_tracker),
      constant(:restart_writer),
      tuple({constant(:tick), integer(0..2_000)})
    ])
  end

  defp step({:write, scope, changes}, s) do
    changes =
      for {n, change} <- changes,
          do: if(change == :delete, do: {:delete, "#{n}.json"}, else: {:put, "#{n}.json", change})

    %{s | cues: s.cues ++ write(s.db, scope, changes, s.now.())}
  end

  defp step({:malformed, scope, n}, s), do: %{s | cues: s.cues ++ malformed(s.db, scope, n)}
  defp step({:deliver, _, _}, %{cues: []} = s), do: s

  defp step({:deliver, i, keep}, s) do
    cue = Enum.at(s.cues, rem(i, length(s.cues)))
    Tracker.cue(s.tracker, cue)
    if keep, do: s, else: %{s | cues: List.delete(s.cues, cue)}
  end

  defp step({:bogus, cue}, s) do
    :ok = Tracker.cue(s.tracker, cue)
    s
  end

  # Cues sent to a stopped Tracker are lost; the new one reads every table in full.
  defp step(:restart_tracker, s) do
    GenServer.stop(s.tracker)
    %{s | tracker: start(s.path, s.now), cues: []}
  end

  defp step(:restart_writer, s) do
    :ok = Sqlite3.close(s.db)
    {:ok, db} = Table.open(s.path)
    assert Table.last_read(db, "h", "never") == :unread
    %{s | db: db}
  end

  defp step({:tick, ms}, s), do: :atomics.add(s.clock, 1, ms) && s

  describe "state rules, over generated event sequences" do
    property "whatever the order of cues, the Tracker's answer is the fold of the tables' rows" do
      check all(events <- list_of(event(), max_length: 30), max_runs: 40) do
        path = Path.join(TestHost.test_dir(), "t.db")
        {:ok, db} = Table.open(path)
        {ref, now} = clock()
        s = %{db: db, path: path, clock: ref, now: now, tracker: start(path, now), cues: []}
        s = Enum.reduce(events, s, &step/2)

        # Every write's cue arrives at last, in reverse order.
        Enum.each(Enum.reverse(s.cues), &Tracker.cue(s.tracker, &1))
        assert {:ok, view} = Tracker.view(s.tracker)
        assert view == reference(path, now.())
        assert view[{"h", "never"}].age == :unread
        GenServer.stop(s.tracker)
      end
    end

    property "a view gets at most one cue a second per topic, and every change reaches one" do
      check all(
              steps <-
                list_of(tuple({integer(0..700), member_of(@written), integer(1..5)}),
                  max_length: 15
                ),
              max_runs: 25
            ) do
        path = Path.join(TestHost.test_dir(), "t.db")
        {:ok, db} = Table.open(path)
        {ref, now} = clock()
        me = self()
        t = start(path, now, &send(me, {:view, now.(), &1}))

        written =
          for {ms, scope, n} <- steps, reduce: MapSet.new() do
            acc ->
              :atomics.add(ref, 1, ms)
              [cue] = write(db, scope, [{:put, "#{n}.json", %{session_id: "s#{n}"}}], now.())
              Tracker.cue(t, cue)
              :ok = Tracker.flush(t)
              Enum.reduce(cue.ids, acc, &MapSet.put(&2, {cue.topic, &1}))
          end

        :atomics.add(ref, 1, 1_000)
        :ok = Tracker.flush(t)
        cues = collect([])

        for {_, times} <- Enum.group_by(cues, &elem(&1, 1).topic, &elem(&1, 0)) do
          assert times
                 |> Enum.chunk_every(2, 1, :discard)
                 |> Enum.all?(fn [a, b] -> b - a >= 1_000 end)
        end

        changed = for {_, cue} <- cues, key <- cue.changed, into: MapSet.new(), do: key
        assert MapSet.subset?(written, changed)
        GenServer.stop(t)
      end
    end

    property "the fold is total: a row of any shape folds, and never changes another's entry" do
      check all(good <- list_of(row(), max_length: 4), bad <- list_of(term(), max_length: 4)) do
        good = good |> Enum.with_index(1) |> Enum.map(fn {row, i} -> Map.put(row, :id, i) end)
        bad = Enum.map(bad, &if(is_map(&1), do: Map.put(&1, :id, {:bad, &1}), else: &1))
        alone = fold_view(good)
        both = fold_view(good ++ bad)

        assert length(both.sessions) > length(alone.sessions) or bad == []
        for entry <- alone.sessions, do: assert(entry in both.sessions)
      end
    end
  end

  defp fold_view(rows) do
    fold = Fold.source(Fold.new(), "t", {"h", "a"}, :sessions)
    {fold, _} = Fold.read(fold, "t", :all, {:ok, %{read_at: nil, rows: rows}})
    Fold.view(fold, 0)[{"h", "a"}]
  end

  defp collect(acc) do
    receive do
      {:view, at, cue} -> collect([{at, cue} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a Registry's reads reach a view; restarts of both and a second instance change nothing" do
    {_, now} = clock()
    me = self()

    [one, two] =
      for n <- [1, 2] do
        dir = TestHost.test_dir()
        File.mkdir_p!(Path.join(dir, "sessions"))
        File.write!(Path.join(dir, "sessions/7.json"), ~s({"pid": 7, "sessionId": "s#{n}"}))
        db = Path.join(dir, "r.db")
        src = [{ReaderSource, table: Table, db: db, host: "test", account: "a"}]

        reg = [
          programs: TestHost.programs(),
          host: TestHost.host(),
          accounts: %{"a" => dir},
          db: db,
          notify: &send(me, {:reg, n, &1})
        ]

        {:ok, t} = Tracker.start_link(sources: src, clock: now, notify: &send(me, {:view, n, &1}))
        {:ok, r} = Registry.start_link(reg)
        %{n: n, src: src, reg: reg, tracker: t, registry: r}
      end

    assert {:ok, %{{"test", "a"} => %{age: :unread, sessions: []}}} = Tracker.view(one.tracker)
    {:ok, _} = Registry.read(one.registry)
    assert_receive {:reg, 1, cue}
    Tracker.cue(one.tracker, cue)
    assert_receive {:view, 1, %{topic: "tracker:test:a", changed: [_, _]}}
    {:ok, view} = Tracker.view(one.tracker)
    assert [%{session_id: "s1", pid: 7, problems: []}] = view[{"test", "a"}].sessions

    # The second instance has read nothing, and heard nothing.
    assert {:ok, %{{"test", "a"} => %{age: :unread}}} = Tracker.view(two.tracker)
    refute_received {:view, 2, _}

    GenServer.stop(one.registry)
    {:ok, _} = Registry.start_link(one.reg)
    GenServer.stop(one.tracker)
    {:ok, again} = Tracker.start_link(sources: one.src, clock: now)
    assert Tracker.view(again) == {:ok, view}
  end

  test "freshness: a source unread or past the bound is named; one that cannot open is shown" do
    dir = TestHost.test_dir()
    db = Path.join(dir, "r.db")
    {ref, now} = clock()
    src = {ReaderSource, table: Table, db: db, host: "h", account: "a"}

    broken =
      {ReaderSource,
       table: Table, db: Path.join(dir, "no/such/dir/r.db"), host: "h", account: "x"}

    {:ok, t} = Tracker.start_link(sources: [src, broken], clock: now)

    assert {:ok, [{"registry:h:a", :unread}, {"registry:h:x", :unread}]} =
             Tracker.behind(t, 1_000)

    {:ok, w} = Table.open(db)
    write(w, {"h", "a"}, [], 0)
    :atomics.put(ref, 1, 500)
    assert {:ok, [{"registry:h:x", :unread}]} = Tracker.behind(t, 1_000)
    {:ok, view} = Tracker.view(t)

    assert %{age: 500, sources: %{"registry:h:a" => %{status: :read, age: 500}}} =
             view[{"h", "a"}]

    assert %{problem: {:refused, {:sqlite, _}}} = view[{"h", "x"}].sources["registry:h:x"]

    :atomics.put(ref, 1, 2_500)
    assert {:ok, [{"registry:h:a", 2_500}, {"registry:h:x", :unread}]} = Tracker.behind(t, 1_000)
  end
end
