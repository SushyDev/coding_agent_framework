defmodule CodingAgentFramework.ReaderTest do
  use ExUnit.Case, async: true

  alias CodingAgentFramework.{Reader, Store, TestHost}

  doctest Reader

  # A reader's table with a scope of two columns, a reads row that can record a failure, and a
  # view that marks each row, as `TmuxSampler.Table` and `Usage.Table` are.
  @meta %{
    schema: """
    CREATE TABLE IF NOT EXISTS r (id INTEGER PRIMARY KEY, host TEXT NOT NULL,
      account TEXT NOT NULL, file TEXT NOT NULL, v TEXT, written_at INTEGER NOT NULL,
      UNIQUE (host, account, file));
    CREATE TABLE IF NOT EXISTS r_reads (host TEXT NOT NULL, account TEXT NOT NULL,
      read_at INTEGER, failed_at INTEGER, problem TEXT, PRIMARY KEY (host, account));
    """,
    table: "r",
    reads: "r_reads",
    scope: [:host, :account],
    key: :file,
    data: [:v],
    read: [:read_at, :failed_at, :problem],
    view: &__MODULE__.mark/2,
    topic: "r",
    kind: :files,
    name: :account,
    failed: :read_failed
  }

  def mark(rows, opts), do: Enum.map(rows, &Map.put(&1, :seen, opts[:account]))

  defp open do
    {:ok, db} = Reader.open(@meta, Path.join(TestHost.test_dir(), "r.db"))
    db
  end

  defp opts(account), do: [host: "h", account: account]

  test "one write of two scopes: each its own ids and first read, in one transaction" do
    db = open()
    a = [{:put, "1", %{v: "x"}}, {:put, "2", %{v: "y"}}]

    assert [%{ids: [one, two], keyed: [{"1", one}, {"2", two}], first: true}, %{ids: [three]}] =
             Reader.write(@meta, db, [
               {opts("a"), a, [read_at: 10]},
               {opts("b"), [{:put, "1", %{v: "z"}}], [read_at: 10]}
             ])

    assert [%{ids: [^two], first: false}] =
             Reader.write(@meta, db, [{opts("a"), [{:delete, "2"}], [read_at: 20]}])

    assert {:ok, %{read_at: 20, rows: [%{id: ^one, file: "1", v: "x"}]}} =
             Reader.rows(@meta, db, opts("a"))

    assert [%{id: ^three, account: "b"}] = Reader.rows_by_id(@meta, db, [one, three], opts("b"))
  end

  test "a source reads only its scope, through the view, and a newer failure is unknown" do
    db = open()
    assert Reader.source_read(@meta, db, opts("a"), :all) == :unread

    [%{ids: [one]}, %{ids: [two]}] =
      Reader.write(@meta, db, [
        {opts("a"), [{:put, "1", %{v: "x"}}], [read_at: 5]},
        {opts("b"), [{:put, "1", %{v: "y"}}], [read_at: 5]}
      ])

    assert {:ok, %{read_at: 5, rows: [%{id: ^one, seen: "a"}]}} =
             Reader.source_read(@meta, db, opts("a"), [one, two])

    assert %{topic: "r:h:a", scope: {"h", "a"}, kind: :files} = Reader.describe(@meta, opts("a"))

    Store.query(db, "UPDATE r_reads SET failed_at = 9, problem = 'gone' WHERE account = 'a'", [])
    assert {:unknown, {:read_failed, 9, "gone"}} = Reader.source_read(@meta, db, opts("a"), :all)
    assert {:ok, %{rows: [_]}} = Reader.source_read(@meta, db, opts("b"), :all)
  end

  test "a cue after a change, a first read or when asked; none otherwise" do
    me = self()
    notify = &send(me, &1)
    :ok = Reader.cue(notify, "t", %{ids: [], first: false})
    refute_received _
    :ok = Reader.cue(notify, "t", %{ids: [], first: true})
    assert_received %{topic: "t", ids: []}
    :ok = Reader.cue(notify, "t", %{ids: [], first: false}, true)
    assert_received %{topic: "t", ids: []}
    :ok = Reader.cue(notify, "t", %{ids: [3], first: false})
    assert_received %{topic: "t", ids: [3]}
  end

  test "a call to a reader that is not there is refused, by the reader's own word" do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert Reader.call(pid, :read, 100, :no_reader) == {:refused, :no_reader}
  end
end
