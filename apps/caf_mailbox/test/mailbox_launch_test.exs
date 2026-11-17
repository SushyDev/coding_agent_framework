defmodule CodingAgentFramework.MailboxLaunchTest do
  @moduledoc """
  The `launch` transport (F-137) over a real `Sessions`, `Transcripts`, real dtach and tmux in
  this test's own directory, and the screen stand-in for Claude Code: the first row to an
  interactive session is marked before its start, carried as the start's prompt through a file,
  and settled by the transcript's user line. Each test names the `Delivery.tla` step it checks.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Grants, Mailbox, ScreenStandIn, Sessions, SessionsSetup}
  alias CodingAgentFramework.Transcripts
  alias CodingAgentFramework.Mailbox.{Table, Transport}
  alias CodingAgentFramework.MailboxLaunchTest.NoWaiter

  doctest Transport.Launch

  setup {SessionsSetup, :sessions}

  setup ctx do
    tree = [
      %{name: "main", project: "app", parent: nil},
      %{name: "d1", project: "app", parent: "main"}
    ]

    db = Path.join(ctx.dir, "caf.db")
    {:ok, accounts} = Accounts.new(Path.join(ctx.dir, "home"), ["work"])

    transcripts =
      start_supervised!({Transcripts, programs: programs(), accounts: ["work"], db: db})

    mopts = [
      db: db,
      grants: Grants.new(fn -> tree end),
      stream: ctx.stream,
      sessions_db: db,
      host: "test",
      intake: start_supervised!(NoWaiter),
      transcripts: transcripts,
      accounts: accounts,
      take_bound: 1_000
    ]

    {:ok, mtable} = Table.open(db)
    {:ok, mopts: mopts, mtable: mtable, mailbox: restart(mopts)}
  end

  # Launch, then the start (the hand-on is the start itself): the row's text goes in as the
  # prompt argument, by a file, and the transcript's user line with its mark delivers it.
  test "the first row goes in as the start's prompt, and its user line settles it", ctx do
    m = mailbox(ctx)
    {:ok, {:queued, one}} = Mailbox.message(m, "d1", "main", "Review it.\nTwo lines.")
    {:ok, {:queued, two}} = Mailbox.message(m, "d1", "main", "after it")
    deadline = System.os_time(:millisecond) + 30_000

    assert {:ok, %{id: ^one, uuid: uuid, text: text}} = Mailbox.launch(m, "main", deadline)
    assert text == "Review it.\nTwo lines.\n\n[delivery #{uuid}]"
    assert %{status: "sending", via: "launch", at: nil} = Table.get(ctx.mtable, one)
    # One row in flight per addressee.
    assert {:refused, {:sending, [^one]}} = Mailbox.launch(m, "main", deadline)

    launch = SessionsSetup.launch(ctx, :at_start)
    launch = Keyword.merge(launch, claude: ScreenStandIn.write!(ctx.dir), prompt: text)

    assert {:ok, %{pid: pid, session_id: sid} = started} =
             Sessions.start(ctx.sessions, "main", ctx.account, launch)

    # The prompt went in whole, as one argument, and its file is gone.
    assert {:ok, [^text]} = await(fn -> nonempty(ScreenStandIn.prompts(ctx.dir)) end)
    refute File.exists?(Path.join([ctx.dir, "d", "main.prompt"]))

    assert {:ok, "sending"} = Mailbox.launched(m, one, {:ok, started})
    assert %{status: "sending", at: ^pid, session_id: ^sid} = Table.get(ctx.mtable, one)

    # Claude Code writes the prompt as the first turn's user line.
    {:ok, path} = Transcripts.path(ctx.account.config_dir, ctx.dir, sid)
    user(path, text)
    assert {:ok, %{status: "delivered"}} = until(ctx, one, &(&1.status == "delivered"))
    assert %{status: "queued"} = Table.get(ctx.mtable, two)
  end

  # Refused undoes the mark: a start refused makes the row due again, under its same uuid.
  # After a restart that lost the start's answer, the evidence decides: no process of the start
  # and no line, the row is due again.
  test "a refused start, or one a restart cut, makes the row due again", ctx do
    m = mailbox(ctx)
    {:ok, {:queued, one}} = Mailbox.message(m, "d1", "main", "Review it.")
    deadline = System.os_time(:millisecond) + 30_000

    {:ok, %{uuid: uuid}} = Mailbox.launch(m, "main", deadline)
    assert {:ok, "queued"} = Mailbox.launched(m, one, {:refused, :setup})
    assert %{status: "queued", uuid: ^uuid, via: nil} = Table.get(ctx.mtable, one)

    {:ok, %{uuid: ^uuid}} = Mailbox.launch(m, "main", deadline)
    GenServer.stop(m)
    Process.put(:mailbox, restart(ctx.mopts))
    assert {:ok, %{status: "queued", uuid: ^uuid}} = until(ctx, one, &(&1.status == "queued"))
  end

  defp user(path, text) do
    File.mkdir_p!(Path.dirname(path))
    line = %{"type" => "user", "uuid" => "u-1", "message" => %{"content" => text}}
    File.write!(path, [JSON.encode!(line), "\n"], [:append])
  end

  defp nonempty([]), do: :empty
  defp nonempty(list), do: {:ok, list}

  defp restart(mopts) do
    spec = Supervisor.child_spec({Mailbox, mopts}, id: make_ref(), restart: :temporary)
    start_supervised!(spec)
  end

  defp mailbox(ctx), do: Process.get(:mailbox, ctx.mailbox)

  defp until(ctx, id, ready?) do
    await(
      fn ->
        Mailbox.cue(mailbox(ctx), %{topic: "transcripts:test:work", ids: []})
        Mailbox.status(mailbox(ctx), 0)
        row = Table.get(ctx.mtable, id)
        if ready?.(row), do: {:ok, row}, else: row
      end,
      10_000
    )
  end
end

defmodule CodingAgentFramework.MailboxLaunchTest.NoWaiter do
  @moduledoc false
  # Plays `Intake` with no waiter held: a launch needs none.
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call({:waiter?, _account, _session}, _from, s), do: {:reply, {:ok, false}, s}
end
