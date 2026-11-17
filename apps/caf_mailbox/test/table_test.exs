defmodule CodingAgentFramework.Mailbox.TableTest do
  @moduledoc "`Mailbox.Table`: one answer per row, one row per uuid, and a file F-77 made."
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Mailbox.Table
  alias CodingAgentFramework.TestHost
  alias Exqlite.Sqlite3

  doctest Table

  test "one reply per answered row, one row per uuid: a second one stores nothing" do
    {:ok, db} = Table.open(Path.join(TestHost.test_dir(), "m.db"))
    id = Table.store(db, reply("app-unit-a", "r1", "m1"))
    assert is_integer(id)
    assert Table.store(db, reply("app-unit-a", "r2", "m1")) == nil
    assert Table.store(db, %{reply("app-unit-a", "r1", "m9") | text: "again"}) == nil
    assert %{reply_to: "m1", text: "done", status: "queued", again: 0} = Table.get(db, id)
    assert [%{id: ^id}] = Table.open_rows(db)
  end

  # Delivery.tla's ReplyOrNotice: one key on the answered row, so the table keeps "never both".
  test "a notice and a reply to one row: the first in keeps it, either way" do
    {:ok, db} = Table.open(Path.join(TestHost.test_dir(), "both.db"))
    notice = Table.store(db, %{reply("framework", "n1", "m1") | kind: "notice"})
    assert Table.store(db, Map.put(reply("app-unit-a", "r1", "m1"), :subtype, "success")) == nil
    reply = Table.store(db, Map.put(reply("app-unit-a", "r2", "m2"), :is_error, true))
    assert Table.store(db, %{reply("framework", "n2", "m2") | kind: "notice"}) == nil

    assert [%{id: ^notice, from_agent: "framework", subtype: nil}, %{id: ^reply, is_error: 1}] =
             Table.open_rows(db)
  end

  # A row made due again goes first among the open rows.
  test "open rows: a row made due again first, then the oldest" do
    {:ok, db} = Table.open(Path.join(TestHost.test_dir(), "order.db"))
    a = Table.store(db, reply("x", "u1", nil))
    b = Table.store(db, reply("x", "u2", nil))
    c = Table.store(db, Map.put(reply("x", "u3", nil), :again, true))
    assert Enum.map(Table.open_rows(db), & &1.id) == [c, a, b]
  end

  test "a file whose table F-77 made opens with its rows and gains its later columns" do
    path = Path.join(TestHost.test_dir(), "old.db")
    {:ok, old} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(old, """
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY, from_agent TEXT NOT NULL, to_agent TEXT NOT NULL,
        text TEXT NOT NULL, uuid TEXT NOT NULL, status TEXT NOT NULL, session_id TEXT,
        attempt TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
      INSERT INTO messages VALUES (1, 'main', 'app-unit-a', 'hi', 'm1', 'delivered', 's1', NULL,
        0, 0);
      """)

    :ok = Sqlite3.close(old)
    {:ok, db} = Table.open(path)
    assert %{uuid: "m1", reply_to: nil, kind: nil, again: 0} = Table.get(db, 1)
    assert [%{id: 1}] = Table.unanswered(db, "s1", ["m1", "m2"])
    assert is_integer(Table.store(db, reply("app-unit-a", "r1", "m1")))
    # A second open finds the columns and the indexes there.
    assert {:ok, _} = Table.open(path)
  end

  defp reply(from, uuid, key),
    do: %{from: from, to: "main", text: "done", uuid: uuid, kind: "reply", reply_to: key}
end
