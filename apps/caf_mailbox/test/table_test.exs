defmodule CodingAgentFramework.Mailbox.TableTest do
  @moduledoc "`Mailbox.Table`: a reply once per answered message, and a file F-77 made."
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Mailbox.Table
  alias CodingAgentFramework.TestHost
  alias Exqlite.Sqlite3

  doctest Table

  test "one reply per answered message: a second one stores nothing" do
    {:ok, db} = Table.open(Path.join(TestHost.test_dir(), "m.db"))
    id = Table.reply(db, "app-unit-a", "main", "done", "r1", "m1")
    assert is_integer(id)
    assert Table.reply(db, "app-unit-a", "main", "again", "r2", "m1") == nil
    assert %{reply_to: "m1", text: "done", status: "queued"} = Table.get(db, id)
    assert [%{id: ^id}] = Table.open_rows(db)
  end

  test "a file whose table F-77 made opens with its rows and gains reply_to" do
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
    assert %{uuid: "m1", reply_to: nil} = Table.get(db, 1)
    assert [%{id: 1}] = Table.delivered(db, "s1", ["m1", "m2"])
    assert is_integer(Table.reply(db, "app-unit-a", "main", "done", "r1", "m1"))
    # A second open finds the column and the index there.
    assert {:ok, _} = Table.open(path)
  end
end
