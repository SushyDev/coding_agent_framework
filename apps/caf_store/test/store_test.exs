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

  test "load fills a newer field and names a field it does not know; bad bytes load fresh" do
    fresh = %{a: 0, b: []}
    assert Store.load(:erlang.term_to_binary(%{a: 1}), fresh) == {%{a: 1, b: []}, []}
    assert Store.load(:erlang.term_to_binary([1]), fresh) == {fresh, [:not_a_map]}
    assert Store.load("not a term", fresh) == {fresh, [:unreadable]}
    assert Store.load(nil, fresh) == {fresh, [:unreadable]}
  end
end
