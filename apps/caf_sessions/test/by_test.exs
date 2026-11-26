defmodule CodingAgentFramework.Sessions.ByTest do
  @moduledoc """
  An app's read of agent rows by session id or by a `meta` key (F-265), in the store's query:
  `Sessions.Agents.read_only/3` over `Sessions.Table.by/3`. The turn state on each row is the
  facade's, read in `caf_surface`'s tests.
  """
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.Sessions.Table, only: [by: 3, where: 1]

  alias CodingAgentFramework.Sessions.{Agents, Table}

  setup do
    path = Path.join(CodingAgentFramework.TestHost.test_dir(), "caf.db")
    {:ok, db} = Table.open(path)

    start = fn name, session, meta ->
      {:ok, text} = Table.meta_text(meta)
      row = %{host: "ws", name: name, socket: name, role: "delegate", session_id: session}
      Table.starting(db, Map.put(row, :meta, text))
    end

    start.("app-one", "s-1", %{"unit" => "u-7", "ticket" => 41})
    start.("app-two", "s-2", %{"unit" => "u-7", "ticket" => "41"})
    start.("app-three", "s-3", %{"unit" => "u-8", "ticket" => true})
    # Another host's row is never this host's answer.
    Table.starting(db, %{host: "other", name: "app-one", socket: "app-one", session_id: "s-1"})
    %{db: db, path: path}
  end

  defp names({:ok, rows}), do: {:ok, Enum.map(rows, & &1.name)}
  defp names(other), do: other

  test "by session id, the one row of this host", ctx do
    assert {:ok, [%{name: "app-two", host: "ws"}]} =
             Agents.read_only(ctx.path, "ws", {:session_id, "s-2"})

    assert {:ok, []} = Agents.read_only(ctx.path, "ws", {:session_id, "s-9"})
  end

  test "by a meta key, every row that holds the value, oldest first", ctx do
    assert names(Agents.read_only(ctx.path, "ws", {:meta, {"unit", "u-7"}})) ==
             {:ok, ["app-one", "app-two"]}

    # An atom key is its string, as `meta_text/1` writes it.
    assert names(Agents.read_only(ctx.path, "ws", {:meta, {:unit, "u-8"}})) ==
             {:ok, ["app-three"]}

    # JSON's type is matched too: 41 is neither "41" nor true.
    assert names(Agents.read_only(ctx.path, "ws", {:meta, {"ticket", 41}})) == {:ok, ["app-one"]}

    assert names(Agents.read_only(ctx.path, "ws", {:meta, {"ticket", "41"}})) ==
             {:ok, ["app-two"]}

    assert names(Agents.read_only(ctx.path, "ws", {:meta, {"ticket", 1}})) == {:ok, []}
  end

  test "no match is no rows; a row with no meta is never one", ctx do
    Table.declare(ctx.db, "ws", "app-main", "app")
    assert {:ok, []} = Agents.read_only(ctx.path, "ws", {:meta, {"unit", "u-9"}})
    assert {:ok, []} = Agents.read_only(ctx.path, "ws", {:meta, {"missing", "u-7"}})
    # A key with a dot is one key, not a path.
    assert {:ok, []} = Agents.read_only(ctx.path, "ws", {:meta, {"unit.x", "u-7"}})
  end

  test "a key of no read, or a value out of shape, is refused before the file is read", ctx do
    assert {:refused, {:bad, :ticket}} = Agents.read_only(ctx.path, "ws", {:ticket, 41})
    assert {:refused, {:bad, :session_id}} = Agents.read_only(ctx.path, "ws", {:session_id, ""})
    assert {:refused, {:bad, :session_id}} = Agents.read_only(ctx.path, "ws", {:session_id, 7})
    assert {:refused, {:bad, :meta}} = Agents.read_only(ctx.path, "ws", {:meta, {"unit", 1.5}})
    assert {:refused, {:bad, :meta}} = Agents.read_only(ctx.path, "ws", {:meta, {"unit", nil}})
    assert {:refused, {:bad, :meta}} = Agents.read_only(ctx.path, "ws", {:meta, {~s(a"b), "x"}})
    assert {:refused, {:bad, :meta}} = Agents.read_only(ctx.path, "ws", {:meta, "unit"})
    assert {:refused, {:bad, :by}} = Agents.read_only(ctx.path, "ws", "s-1")

    missing = Path.join(Path.dirname(ctx.path), "none.db")
    assert {:refused, {:bad, :ticket}} = Agents.read_only(missing, "ws", {:ticket, 41})
  end

  test "a row resumed into a new session id is found by that id, not the earlier one", ctx do
    # A resume starts the row again, naming the id it resumes, and `Sessions` writes the id the
    # session's file names once it reads it: the row keeps only the current one.
    id = Table.starting(ctx.db, %{host: "ws", name: "app-two", socket: "app-two", resume: "s-2"})
    :ok = Table.update(ctx.db, id, session_id: "s-2b")

    assert names(Agents.read_only(ctx.path, "ws", {:session_id, "s-2b"})) == {:ok, ["app-two"]}
    assert {:ok, []} = Agents.read_only(ctx.path, "ws", {:session_id, "s-2"})
  end

  test "the session id read uses its index", ctx do
    plan =
      CodingAgentFramework.Store.query(
        ctx.db,
        "EXPLAIN QUERY PLAN SELECT id FROM agents WHERE host = ?1 AND session_id = ?2",
        ["ws", "s-1"]
      )

    assert Enum.any?(plan, fn row -> List.last(row) =~ "agents_session" end)
  end
end
