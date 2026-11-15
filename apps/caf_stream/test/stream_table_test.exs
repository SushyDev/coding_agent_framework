defmodule CodingAgentFramework.StreamTableTest do
  @moduledoc """
  A stored fold an earlier or later build wrote loads without dropping what it can keep
  (`docs/design.md`, "State that never lags or lies", rule 4): the bytes are rewritten in place
  of a row's fold, then the row is read as the reader and as the writer see it.
  """
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Stream.{Fold, Table}
  alias CodingAgentFramework.TestHost
  alias Exqlite.Sqlite3

  @host "laptop"

  setup do
    {:ok, db} = Table.open(Path.join(TestHost.test_dir(), "stream.db"))

    fold = %{
      Fold.new()
      | offset: 42,
        session_id: "s1",
        resumes: 2,
        ending: true,
        messages: %{"u1" => %{state: :delivered, at: 0, result: nil, exited: false}}
    }

    delegate = %{socket: "/tmp/s", transcript: "/tmp/t.jsonl", fold: fold}
    [_id] = Table.write(db, @host, [{"s1", delegate}], 1_000)
    %{db: db, fold: fold}
  end

  # What `Stream` never does: puts other bytes where a fold was.
  defp rewrite(db, bytes) do
    {:ok, stmt} = Sqlite3.prepare(db, "UPDATE stream_delegates SET fold = ?1")
    :ok = Sqlite3.bind(stmt, [{:blob, bytes}])
    :done = Sqlite3.step(db, stmt)
    :ok = Sqlite3.release(db, stmt)
  end

  defp row(db) do
    {:ok, %{rows: [row]}} = Table.rows(db, @host)
    row
  end

  defp writers_fold(db), do: Table.delegates(db, @host)["s1"].fold

  test "a fold as the writer wrote it loads whole, with no problem", %{db: db, fold: fold} do
    assert %{offset: 42, ending: true, load_problems: []} = row(db)
    assert writers_fold(db) == fold
  end

  test "a fold lacking a field loads with its default and keeps the rest", %{db: db, fold: fold} do
    rewrite(db, :erlang.term_to_binary(Map.delete(fold, :ending)))

    assert %{offset: 42, ending: false, resumes: 2, load_problems: []} = row(db)
    assert %{offset: 42, ending: false, session_id: "s1"} = writers_fold(db)
    assert %{"u1" => %{state: :delivered}} = writers_fold(db).messages
  end

  test "a message an earlier build stored takes its result from the last one", %{db: db} do
    old = %{
      Fold.new()
      | messages: %{"u1" => %{state: :delivered, at: 0}, "u2" => %{state: :delivered, at: 0}},
        last_result: %{
          text: "ok",
          subtype: "success",
          is_error: false,
          user_message_uuids: ["u1"]
        }
    }

    rewrite(db, :erlang.term_to_binary(old))

    assert %{load_problems: []} = row(db)

    assert Fold.outcome(writers_fold(db), "u1") ==
             {:result, Map.delete(old.last_result, :user_message_uuids)}

    assert %{result: nil, exited: false} = writers_fold(db).messages["u2"]
  end

  test "a fold with an extra field loses it and names it", %{db: db, fold: fold} do
    rewrite(db, :erlang.term_to_binary(Map.put(fold, :extra_field, 1)))

    assert %{offset: 42, ending: true, load_problems: [{:unknown_fields, [:extra_field]}]} =
             row = row(db)

    refute Map.has_key?(row, :extra_field)
    assert writers_fold(db) == fold
  end

  test "a fold lacking one field and holding another is both", %{db: db, fold: fold} do
    rewrite(db, :erlang.term_to_binary(fold |> Map.delete(:ending) |> Map.put(:extra_field, 1)))

    assert %{offset: 42, ending: false, load_problems: [{:unknown_fields, [:extra_field]}]} =
             row(db)
  end

  test "bytes that are not a term load as a new fold, with a problem", %{db: db} do
    rewrite(db, "not a term")

    assert %{offset: 0, messages: messages, load_problems: [:unreadable]} = row(db)
    assert messages == %{}
    assert writers_fold(db) == Fold.new()
  end

  test "a term that is not a map loads as a new fold, with a problem", %{db: db} do
    rewrite(db, :erlang.term_to_binary([1, 2]))

    assert %{offset: 0, load_problems: [:not_a_map]} = row(db)
    assert writers_fold(db) == Fold.new()
  end

  test "rows_by_id answers the same problems as rows", %{db: db, fold: fold} do
    rewrite(db, :erlang.term_to_binary(Map.put(fold, :extra_field, 1)))

    %{id: id} = row(db)

    assert [%{id: ^id, offset: 42, load_problems: [{:unknown_fields, [:extra_field]}]}] =
             Table.rows_by_id(db, @host, [id])
  end
end
