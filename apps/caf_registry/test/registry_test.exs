defmodule CodingAgentFramework.RegistryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CodingAgentFramework.{Registry, SessionFiles, Shell, TestHost}
  alias CodingAgentFramework.Registry.{SessionFile, Table}

  doctest CodingAgentFramework.Registry
  doctest CodingAgentFramework.Registry.SessionFile
  doctest CodingAgentFramework.Registry.Table

  defp start(dir, opts \\ []) do
    File.mkdir_p!(Path.join(dir, "sessions"))
    me = self()

    opts =
      Keyword.merge(
        [
          programs: TestHost.programs(),
          account: "a",
          config_dir: dir,
          db: Path.join(dir, "registry.db"),
          notify: &send(me, {:cue, &1})
        ],
        opts
      )

    {:ok, reg} = Registry.start_link(opts)
    reg
  end

  defp put(dir, file, content),
    do: File.write!(Path.join([dir, "sessions", file]), content)

  defp lstart(pid) do
    {out, 0} =
      System.cmd(TestHost.program!(:ps), ["-o", "lstart=", "-p", "#{pid}"],
        env: [{"LC_ALL", "C"}, {"TZ", "UTC"}]
      )

    String.trim(out)
  end

  defp by_file(reg) do
    {:ok, %{rows: rows}} = Registry.rows(reg)
    Map.new(rows, &{&1.file, &1})
  end

  describe "reading" do
    test "a missing sessions directory is a read with no rows, after :unread" do
      dir = TestHost.test_dir()

      {:ok, reg} =
        Registry.start_link(
          programs: TestHost.programs(),
          account: "a",
          config_dir: dir,
          db: Path.join(dir, "r.db")
        )

      assert Registry.rows(reg) == :unread
      assert {:ok, %{files: 0, problems: 0, ids: []}} = Registry.read(reg)
      assert {:ok, %{rows: [], files: 0}} = Registry.rows(reg)
    end

    test "liveness by pid and start time: live, replaced, gone" do
      dir = TestHost.test_dir()
      reg = start(dir)
      me = String.to_integer(System.pid())
      # A pid that has exited and been reaped once the run returns. A port's own pid could not be
      # read when the program exited before `Port.info/2`.
      {:ok, %{status: 0, output: out}} =
        Shell.run(TestHost.host(), TestHost.program!(:sh), ["-c", "echo $$"], timeout: 5_000)

      gone = String.to_integer(String.trim(out))

      put(dir, "1.json", JSON.encode!(%{pid: me, sessionId: "live", procStart: lstart(me)}))

      put(
        dir,
        "2.json",
        JSON.encode!(%{pid: me, sessionId: "reused", procStart: "Thu Jan  1 00:00:00 1970"})
      )

      put(dir, "3.json", JSON.encode!(%{pid: gone, sessionId: "gone", procStart: "x"}))
      put(dir, "4.json", JSON.encode!(%{pid: me, sessionId: "no start"}))

      assert {:ok, %{files: 4}} = Registry.read(reg)
      rows = by_file(reg)
      assert rows["1.json"].alive == :live
      assert rows["2.json"].alive == :replaced
      assert rows["3.json"].alive == :gone
      assert rows["4.json"].alive == :unknown
    end

    test "a ps that fails, or does not answer in time, answers unknown, not gone" do
      dir = TestHost.test_dir()
      failing = Path.join(dir, "ps-fails")
      sh = TestHost.program!(:sh)
      File.write!(failing, "#!#{sh}\necho 'ps: cannot read' >&2\nexit 1\n")
      slow = Path.join(dir, "ps-slow")
      File.write!(slow, "#!#{sh}\nexec #{TestHost.program!(:sleep)} 5\n")
      Enum.each([failing, slow], &File.chmod!(&1, 0o755))
      me = String.to_integer(System.pid())

      for {ps, n} <- [{failing, 1}, {slow, 2}, {"/no/such/ps", 3}] do
        d = Path.join(dir, "#{n}")
        reg = start(d, programs: TestHost.programs(TestHost.host(), %{ps: ps}), timeout: 300)
        put(d, "1.json", JSON.encode!(%{pid: me, sessionId: "s", procStart: lstart(me)}))
        assert {:ok, %{files: 1}} = Registry.read(reg)
        assert by_file(reg)["1.json"].alive == :unknown
      end
    end

    test "a half-written file keeps the last good data and names the problem; a gone file is deleted" do
      dir = TestHost.test_dir()
      reg = start(dir)
      good = JSON.encode!(%{pid: 7, sessionId: "s7", name: "alpha", status: "busy", future: [1]})
      put(dir, "7.json", good)
      assert {:ok, %{ids: [id]}} = Registry.read(reg)
      assert_receive {:cue, %{ids: [^id]}}
      assert %{name: "alpha", problem: nil, extra: %{"future" => [1]}} = by_file(reg)["7.json"]

      put(dir, "7.json", binary_part(good, 0, 20))
      assert {:ok, %{problems: 1, ids: [^id]}} = Registry.read(reg)
      assert %{name: "alpha", session_id: "s7", problem: ":not_json"} = by_file(reg)["7.json"]

      put(dir, "7.json", good)
      assert {:ok, %{problems: 0, ids: [^id]}} = Registry.read(reg)
      assert {:ok, %{ids: []}} = Registry.read(reg)

      File.rm!(Path.join(dir, "sessions/7.json"))
      assert {:ok, %{files: 0, ids: [^id]}} = Registry.read(reg)
      assert {:ok, %{rows: []}} = Registry.rows(reg)
    end

    test "a restarted Registry resumes from its table; two accounts in one file stay apart" do
      dir = TestHost.test_dir()
      reg = start(dir)
      put(dir, "7.json", JSON.encode!(%{pid: 7, sessionId: "s7"}))
      {:ok, _} = Registry.read(reg)
      GenServer.stop(reg)

      again = start(dir)
      assert {:ok, %{files: 1, rows: [%{session_id: "s7"}]}} = Registry.rows(again)
      assert {:ok, %{ids: []}} = Registry.read(again)

      other = start(dir, account: "b", config_dir: Path.join(dir, "b"))
      assert Registry.rows(other) == :unread
      assert {:ok, %{files: 0}} = Registry.read(other)
      assert {:ok, %{files: 1}} = Registry.rows(again)
    end
  end

  describe "state rules, over generated session files" do
    property "parsing is total: every file is a row or a named problem" do
      check all({kind, bytes} <- SessionFiles.file()) do
        case {kind, SessionFile.parse(bytes)} do
          {:good, {:ok, %{problems: []}}} -> :ok
          {:odd, {:ok, %{problems: [{:wrong_type, _}]}}} -> :ok
          {:bad, {:malformed, _}} -> :ok
        end
      end
    end

    property "unknown keys are kept as data" do
      check all(map <- SessionFiles.good()) do
        {:ok, row} = SessionFile.parse(JSON.encode!(map))
        known = ~w(pid sessionId cwd name nameSource status version kind entrypoint procStart
                   startedAt statusUpdatedAt updatedAt)
        assert row.extra == Map.drop(map, known)
      end
    end

    # Its 15 runs read 3 times each, and a read runs one `ps` through `Shell`. The test took 5 to
    # 6.5 s on a quiet machine, and 11 to 95 s in 30 runs beside other tests (load average 16 to
    # 80), five of them past ExUnit's 60 s. Nearly all of it is those 45 reads (11 s of 11.6 s in
    # one run; the generated files take 0.15 s and the table reads 0.02 s), so a smaller generator
    # would save nothing and fewer runs would check less. The bound is raised to 5 minutes, three
    # times the longest run.
    @tag timeout: 300_000
    property "reads count and name every file, and each cue names only ids it wrote" do
      check all(
              gens <-
                list_of(map_of(integer(1..40), SessionFiles.file(), max_length: 8), length: 3),
              max_runs: 15
            ) do
        dir = TestHost.test_dir()
        reg = start(dir)
        assert Registry.rows(reg) == :unread
        {:ok, db} = Table.open(Path.join(dir, "registry.db"))

        Enum.reduce(gens, {%{}, true}, fn files, {before, first} ->
          File.rm_rf!(Path.join(dir, "sessions"))
          File.mkdir_p!(Path.join(dir, "sessions"))
          Enum.each(files, fn {n, {_, bytes}} -> put(dir, "#{n}.json", bytes) end)

          bad = Enum.count(files, fn {_, {kind, _}} -> kind != :good end)
          assert {:ok, %{files: n, problems: ^bad, ids: ids}} = Registry.read(reg)
          assert n == map_size(files)

          {:ok, %{rows: rows}} = Registry.rows(reg)

          assert Enum.sort(Enum.map(rows, & &1.file)) ==
                   Enum.sort(Enum.map(files, &"#{elem(&1, 0)}.json"))

          # Rows not named by the cue are exactly as they were before the read.
          now = Map.new(rows, &{&1.id, &1})
          for {id, row} <- before, id not in ids, do: assert(now[id] == row)
          for {id, _} <- now, not Map.has_key?(before, id), do: assert(id in ids)

          if ids != [] or first do
            assert_receive {:cue, cue}
            # A small map's atom keys come in the atoms' creation order, which depends on what
            # ran before in this VM; compare them sorted.
            assert Enum.sort(Map.keys(cue)) == [:ids, :topic] and cue.ids == ids
            assert Enum.all?(Table.rows_by_id(db, ids), &(&1.id in ids))
          else
            refute_received {:cue, _}
          end

          {now, false}
        end)

        GenServer.stop(reg)
      end
    end
  end
end
