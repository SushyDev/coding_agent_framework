defmodule CodingAgentFramework.StoreTest do
  use ExUnit.Case, async: true

  alias CodingAgentFramework.{Store, TestHost}

  doctest Store

  @columns [:id, :host, :a]
  @schema "CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, host TEXT NOT NULL, a TEXT);"

  defp path, do: Path.join(TestHost.test_dir(), "#{System.unique_integer([:positive])}.db")

  test "an older file gains the added columns, and opening again adds none twice" do
    path = path()
    {:ok, db} = Store.open(path, @schema)
    [[1]] = Store.insert(db, "t", [host: "h", a: "x"], "RETURNING id")

    added = [added: [t: ["b INTEGER", "c TEXT NOT NULL DEFAULT 'none'"]]]
    assert {:ok, _} = Store.open(path, @schema, added)
    assert {:ok, db} = Store.open(path, @schema, added)
    assert Store.select(db, "t", [:id, :b, :c], "1 = 1", []) == [%{id: 1, b: nil, c: "none"}]
  end

  test "a statement run after the columns may use them" do
    opts = [added: [t: ["r TEXT"]], then: "CREATE UNIQUE INDEX IF NOT EXISTS t_r ON t (r)"]
    {:ok, db} = Store.open(path(), @schema, opts)

    assert [[_]] =
             Store.insert(db, "t", [host: "h", r: "u"], "ON CONFLICT DO NOTHING RETURNING id")

    assert [] = Store.insert(db, "t", [host: "h", r: "u"], "ON CONFLICT DO NOTHING RETURNING id")
  end

  test "a schema SQLite refuses is refused, with SQLite's reason" do
    assert {:refused, {:sqlite, _}} = Store.open(path(), "CREATE TABLE (")
  end

  test "the file is in WAL mode" do
    {:ok, db} = Store.open(path(), @schema)
    assert Store.query(db, "PRAGMA journal_mode", []) == [["wal"]]
  end

  test "rows_by_id answers the scope's rows with those ids, oldest first" do
    {:ok, db} = Store.open(path(), @schema)
    for host <- ~w(h h g h), do: Store.insert(db, "t", host: host, a: nil)

    assert [%{id: 2}, %{id: 4}] = Store.rows_by_id(db, "t", @columns, [4, 3, 2, 9], host: "h")
    assert [%{id: 3}] = Store.rows_by_id(db, "t", @columns, [3])
    assert Store.rows_by_id(db, "t", @columns, []) == []
  end

  test "update stores a term by text/1's one rule, never as inspect text" do
    {:ok, db} = Store.open(path(), @schema)
    Store.insert(db, "t", host: "h", a: "x")
    Store.update(db, "t", 1, a: :repeating)
    assert [%{a: "repeating"}] = Store.select(db, "t", @columns, "id = ?1", [1])
    Store.update(db, "t", 1, a: {:exit, 3})
    assert [%{a: ~s(["exit",3])}] = Store.select(db, "t", @columns, "id = ?1", [1])
  end

  test "convert turns the inspect text an earlier build stored into text/1's, once" do
    {:ok, db} = Store.open(path(), @schema)
    old = [":repeating", "{:sample_too_old, 31001}", "%{a: [1, nil]}", "plain", nil]
    for a <- old, do: Store.insert(db, "t", host: "h", a: a)
    Store.update(db, "t", 5, a: %{b: {:x, 1}})

    assert Store.convert(db, "t", [:a]) == 3

    assert ["repeating", ~s(["sample_too_old",31001]), ~s({"a":[1,null]}), "plain", json] =
             Enum.map(Store.select(db, "t", [:a], "1 = 1 ORDER BY id", []), & &1.a)

    assert json == ~s({"b":["x",1]})
    assert Store.convert(db, "t", [:a]) == 0
  end

  # F-130's new-2: a reader's reads table has no `id`; its problem converts by `rowid`, at the
  # reader's open.
  test "a reader's open converts the columns its meta names, in a table keyed by scope" do
    schema = "CREATE TABLE IF NOT EXISTS r (host TEXT PRIMARY KEY, problem TEXT);"
    meta = %{schema: schema, convert: [{"r", [:problem]}]}
    path = path()
    {:ok, db} = Store.open(path, schema)
    Store.upsert(db, "r", host: "h", problem: "{:unreadable, :eacces}")
    Store.upsert(db, "r", host: "g", problem: "not_json")
    {:ok, db} = CodingAgentFramework.Reader.open(meta, path)

    assert Store.select(db, "r", [:host, :problem], "1 = 1 ORDER BY host", []) == [
             %{host: "g", problem: "not_json"},
             %{host: "h", problem: ~s(["unreadable","eacces"])}
           ]
  end

  test "upsert writes a row in place of the one with its key" do
    {:ok, db} = Store.open(path(), @schema)
    Store.upsert(db, "t", id: 1, host: "h", a: "x")
    Store.upsert(db, "t", id: 1, host: "g", a: nil)
    assert Store.select(db, "t", @columns, "1 = 1", []) == [%{id: 1, host: "g", a: nil}]
  end

  test "a transaction saves what it writes and answers what its function answers" do
    {:ok, db} = Store.open(path(), @schema)
    assert :done = Store.transaction(db, fn -> Store.insert(db, "t", host: "h") && :done end)
    assert [%{id: 1}] = Store.select(db, "t", @columns, "1 = 1", [])
  end

  test "a transaction whose function raises is rolled back, and the next one runs" do
    {:ok, db} = Store.open(path(), @schema)

    assert_raise RuntimeError, "half done", fn ->
      Store.transaction(db, fn ->
        Store.insert(db, "t", host: "h")
        raise "half done"
      end)
    end

    assert Store.select(db, "t", @columns, "1 = 1", []) == []
    assert :ok = Store.transaction(db, fn -> Store.insert(db, "t", host: "g") && :ok end)
    assert [%{host: "g"}] = Store.select(db, "t", @columns, "1 = 1", [])
  end

  # F-216: a busy answer comes after the bound and no later than the bound and its slack. The
  # slack covers the last try's own run and the scheduler on a loaded host: 100 ms failed at
  # 2,168 ms with three gate runs and a live end-to-end run on one machine (F-224).
  @slack 500

  # Holds `path`'s write lock from a second connection while `write` runs, and answers what
  # `write` answered or raised and how long it took, in ms by the monotonic clock.
  defp against_held(path, write) do
    {:ok, held} = Store.hold(path)

    try do
      began = System.monotonic_time(:millisecond)
      answer = try(do: write.(), rescue: (e in Store.Busy -> {:raised, e}))
      {answer, System.monotonic_time(:millisecond) - began}
    after
      Store.let_go(held)
    end
  end

  defp assert_bounded(ms) do
    assert ms >= Store.busy_bound()
    assert ms <= Store.busy_bound() + @slack
  end

  test "a statement against a held lock raises Busy within the bound; after the let-go it runs" do
    path = path()
    {:ok, db} = Store.open(path, @schema)

    assert {{:raised, %Store.Busy{waited: waited}}, ms} =
             against_held(path, fn -> Store.insert(db, "t", host: "h") end)

    assert_bounded(ms)
    assert waited >= Store.busy_bound() and waited <= ms
    assert [[1]] = Store.insert(db, "t", [host: "h"], "RETURNING id")
  end

  test "a transaction against a held lock raises Busy within the bound and begins nothing" do
    path = path()
    {:ok, db} = Store.open(path, @schema)

    assert {{:raised, %Store.Busy{}}, ms} =
             against_held(path, fn -> Store.transaction(db, fn -> :ran end) end)

    assert_bounded(ms)
    assert :ran = Store.transaction(db, fn -> Store.insert(db, "t", host: "h") && :ran end)
  end

  test "write and open against a held lock are refused busy within the bound, under one deadline" do
    path = path()
    {:ok, _} = Store.open(path, @schema)
    write = fn -> Store.write(path, @schema, &Store.insert(&1, "t", host: "h")) end
    assert {{:refused, {:sqlite, :busy}}, ms} = against_held(path, write)
    assert_bounded(ms)

    # Two columns to add: two statements that each meet the lock, and one bound for both.
    added = [added: [t: ["b TEXT", "c TEXT"]]]
    open = fn -> Store.open(path, @schema, added) end
    assert {{:refused, {:sqlite, :busy}}, ms} = against_held(path, open)
    assert_bounded(ms)

    assert {:ok, []} = write.()
    assert {:ok, _} = open.()
  end

  # F-267: a reader of a WAL file reads the last commit while a writer holds the write lock.
  test "a read-only read against a held write lock answers at once, the last commit" do
    path = path()
    {:ok, db} = Store.open(path, @schema)
    Store.insert(db, "t", host: "h")
    read = &Store.query(&1, "SELECT host FROM t", [])

    assert {{:ok, [["h"]]}, ms} =
             against_held(path, fn -> Store.read_only(path, "t", [], read) end)

    assert ms < Store.busy_bound()

    snapshot = fn -> Store.snapshot(path, fn db, _tables -> read.(db) end) end
    assert {{:ok, [["h"]]}, ms} = against_held(path, snapshot)
    assert ms < Store.busy_bound()
  end

  # Only a lock that shuts readers out, such as an exclusive one on a file not in WAL, makes a
  # reader wait; it is refused busy within the bound.
  test "a read-only read against an exclusive lock is refused busy within the bound" do
    path = path()
    {:ok, writer} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(writer, "CREATE TABLE t (host TEXT)")
    :ok = Exqlite.Sqlite3.execute(writer, "BEGIN EXCLUSIVE")

    try do
      began = System.monotonic_time(:millisecond)
      read = &Store.query(&1, "SELECT host FROM t", [])
      assert {:refused, {:sqlite, :busy}} = Store.read_only(path, "t", [], read)
      assert_bounded(System.monotonic_time(:millisecond) - began)
    after
      Exqlite.Sqlite3.close(writer)
    end
  end

  test "a write waits while the lock is held and runs once it is let go, before the bound" do
    path = path()
    {:ok, db} = Store.open(path, @schema)
    me = self()

    holder =
      spawn_link(fn ->
        {:ok, held} = Store.hold(path)
        send(me, :held)
        receive(do: (:let_go -> Store.let_go(held)))
        send(me, :let_go)
      end)

    assert_receive :held
    began = System.monotonic_time(:millisecond)
    Process.send_after(holder, :let_go, 200)
    assert [[1]] = Store.insert(db, "t", [host: "h"], "RETURNING id")
    ms = System.monotonic_time(:millisecond) - began
    assert_receive :let_go
    assert ms >= 200 and ms < Store.busy_bound()
  end

  test "load fills a newer field and names a field it does not know; bad bytes load fresh" do
    fresh = %{a: 0, b: []}
    assert Store.load(:erlang.term_to_binary(%{a: 1}), fresh) == {%{a: 1, b: []}, []}
    assert Store.load(:erlang.term_to_binary([1]), fresh) == {fresh, [:not_a_map]}
    assert Store.load("not a term", fresh) == {fresh, [:unreadable]}
    assert Store.load(nil, fresh) == {fresh, [:unreadable]}
  end
end
