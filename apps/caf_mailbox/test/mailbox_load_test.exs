defmodule CodingAgentFramework.MailboxLoadTest.Parts do
  @moduledoc false
  # Plays `Intake` and `Stream` for the load test: every session has a waiter, a delivery is
  # sent at once, and Stream follows no session.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(arg), do: {:ok, arg}

  @impl true
  def handle_call({:waiter?, _account, _session}, _from, s), do: {:reply, {:ok, true}, s}
  def handle_call({:deliver, _account, _session, _text}, _from, s), do: {:reply, {:ok, :sent}, s}
  def handle_call(:read, _from, s), do: {:reply, {:ok, %{ids: []}}, s}
  def handle_call(:rows, _from, s), do: {:reply, {:ok, %{rows: []}}, s}
end

defmodule CodingAgentFramework.MailboxLoadTest do
  @moduledoc """
  `Mailbox` with many rows in flight and a slow transcript read (F-289): `Transcripts` runs a
  `tail` stand-in that waits before each read, as a loaded host's does. Every interactive row
  is sent by the waiter and stays `sending` until its transcript shows its line, so each
  settle reads every one of them. A call answers within its bound meanwhile, and the rows still
  settle by their lines.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Grants, Mailbox, Transcripts}
  alias CodingAgentFramework.Mailbox.{Table, Transport}
  alias CodingAgentFramework.MailboxLoadTest.Parts
  alias CodingAgentFramework.Sessions.Table, as: Agents

  @rows 20
  # How long the stand-in holds each read: a pass reads two per row, so 20 rows hold a pass
  # for about 16 s, far past a call's 5 s bound.
  @hold "0.4"
  # A Mailbox call's bound: the 5 s every call but `await/4` and `reload_plugins/3` takes.
  @bound 5_000

  setup do
    dir = test_dir()
    db = Path.join(dir, "caf.db")
    names = for n <- 1..@rows, do: "a#{n}"

    tree =
      [%{name: "lead", project: "app", parent: nil}] ++
        for(name <- ["fresh", "back" | names], do: %{name: name, project: "app", parent: "lead"})

    {:ok, accounts} = Accounts.new(Path.join(dir, "home"), ["work"])
    {:ok, config} = Accounts.config_dir(accounts, "work")
    cwd = Path.join(dir, "work")
    File.mkdir_p!(cwd)
    {:ok, sessions} = Agents.open(db)

    files =
      for name <- ["back" | names], into: %{} do
        sid = "sid-" <> name
        # `back` stopped: its next start is a resume of its session.
        status = if name == "back", do: "stopped", else: "running"

        id =
          Agents.starting(sessions, %{
            host: "test",
            name: name,
            role: "parent",
            account: "work",
            cwd: cwd,
            project: "app",
            socket: name
          })

        :ok = Agents.update(sessions, id, status: status, pid: 4_000_000, session_id: sid)
        {:ok, path} = Transcripts.path(config, cwd, sid)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, ~s({"type":"user","message":{"content":"hello"}}\n))
        {name, path}
      end

    tail = Path.join(dir, "slow-tail")
    File.write!(tail, "#!#{program!(:sh)}\nsleep #{@hold}\nexec #{program!(:tail)} \"$@\"\n")
    File.chmod!(tail, 0o755)

    transcripts =
      start_supervised!(
        {Transcripts, programs: programs(host(), %{tail: tail}), accounts: ["work"], db: db}
      )

    # The reader has read `back`'s transcript: its offset is in memory.
    {:ok, %{failed: []}} =
      Transcripts.read(transcripts, [{"work", "sid-back", files["back"]}], timeout: 30_000)

    parts = start_supervised!({Parts, nil})
    me = self()

    mailbox =
      start_supervised!(
        {Mailbox,
         db: db,
         grants: Grants.new(fn -> tree end),
         stream: parts,
         sessions_db: db,
         host: "test",
         intake: parts,
         transcripts: transcripts,
         accounts: accounts,
         take_bound: 600_000,
         notify: &send(me, {:cue, &1})}
      )

    {:ok, mtable} = Table.open(db)
    {:ok, mailbox: mailbox, mtable: mtable, files: files, names: names, transcripts: transcripts}
  end

  test "message, launch and ended answer within the bound while a pass reads every row", ctx do
    m = ctx.mailbox

    ids =
      for name <- ctx.names do
        {:ok, {:queued, id}} = Mailbox.message(m, "lead", name, "go on")
        id
      end

    # Each row is marked and handed on, and stays sending: no line of it yet.
    {:ok, _} = await(fn -> if Enum.all?(ids, &sending?(ctx, &1)), do: {:ok, true} end, 60_000)

    {:ok, {:queued, back}} = Mailbox.message(m, "lead", "back", "welcome back")

    # A transcripts cue starts a pass that reads all of them, a slow read each. A message with
    # no bound of its own shows how long the pass keeps a call waiting.
    Mailbox.cue(m, %{topic: "transcripts:test:work"})
    {_, waited} = timed(fn -> Mailbox.message(m, "lead", "fresh", "first", timeout: 120_000) end)

    # Another pass, and the calls with their bound meanwhile.
    Mailbox.cue(m, %{topic: "transcripts:test:work"})
    times = for call <- calls(ctx), do: timed(call)

    assert waited < @bound, "a message waited #{waited} ms"

    for {answer, ms} <- times do
      assert ms < @bound, "#{inspect(answer)} took #{ms} ms"
    end

    assert [{:ok, {:queued, _}}, {:ok, %{id: _}}, {:ok, %{id: ^back}}, {:ok, [_]}] =
             Enum.map(times, &elem(&1, 0))

    # The resume's launch read its offset from the reader's memory, before its answer.
    size = File.stat!(ctx.files["back"]).size
    {:ok, _} = await(fn -> if Table.get(ctx.mtable, back).from_byte == size, do: {:ok, true} end)

    # Each row's line comes: the next passes settle every row delivered.
    for id <- ids do
      %{uuid: uuid, to_agent: name} = Table.get(ctx.mtable, id)

      line =
        JSON.encode!(%{
          type: "queue-operation",
          operation: "dequeue",
          content: Transport.Waiter.text("go on", uuid)
        })

      File.write!(ctx.files[name], line <> "\n", [:append])
    end

    Mailbox.cue(m, %{topic: "transcripts:test:work"})

    {:ok, _} =
      await(fn -> if Enum.all?(ids, &delivered?(ctx, &1)), do: {:ok, true} end, 120_000)
  end

  # The calls the brief names, each made while the pass reads.
  defp calls(ctx) do
    m = ctx.mailbox
    deadline = System.os_time(:millisecond) + 60_000

    [
      fn -> Mailbox.message(m, "lead", "fresh", "a new one") end,
      fn -> Mailbox.launch(m, "fresh", deadline) end,
      fn -> Mailbox.launch(m, "back", deadline) end,
      fn -> Mailbox.ended(m, "fresh") end
    ]
  end

  defp timed(call) do
    started = System.monotonic_time(:millisecond)
    answer = call.()
    {answer, System.monotonic_time(:millisecond) - started}
  end

  defp sending?(ctx, id),
    do: match?(%{status: "sending", sent_at: at} when is_integer(at), Table.get(ctx.mtable, id))

  defp delivered?(ctx, id), do: match?(%{status: "delivered"}, Table.get(ctx.mtable, id))
end
