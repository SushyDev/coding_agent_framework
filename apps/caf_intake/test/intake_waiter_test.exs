defmodule CodingAgentFramework.IntakeWaiterTest do
  @moduledoc """
  The waiter: one per session, text handed once, its deadline, a second waiter behind the
  first, a connection that dies unseen, and the real hook program against a real socket.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.IntakeSetup
  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.Intake

  setup {CodingAgentFramework.IntakeSetup, :intake}

  @stop body("Stop")

  # A stand-in for the plug: it holds a waiter for session s1 and tells the test what it gets.
  defp stand_in(intake) do
    me = self()

    pid =
      spawn(fn ->
        {:ok, {:waiting, key, ref, _, _}} = Intake.wait(intake, "work", @stop)
        send(me, {:held, self(), key, ref})
        relay(me)
      end)

    assert_receive {:held, ^pid, key, ref}, 5_000
    {pid, key, ref}
  end

  defp relay(me) do
    receive do
      {:stop} ->
        :ok

      message ->
        send(me, {:got, self(), message})
        relay(me)
    end
  end

  defp waiter?(intake), do: Intake.waiter?(intake, "work", "s1")

  defp await_waiter(intake, want) do
    await(fn -> if waiter?(intake) == {:ok, want}, do: {:ok, want}, else: :not_yet end)
  end

  test "text goes to the session's waiter as the last chunk, once", %{start: start} do
    intake = start.([])
    assert {:refused, :no_waiter} = Intake.deliver(intake, "work", "s1", "hello")
    task = Task.async(fn -> post(intake, @stop, path: "/hooks/work/waiter") end)
    assert {:ok, true} = await_waiter(intake, true)
    assert {:refused, :empty_text} = Intake.deliver(intake, "work", "s1", " \n")
    assert {:ok, :sent} = Intake.deliver(intake, "work", "s1", "hello")
    conn = Task.await(task)
    assert conn.status == 200
    assert String.trim(conn.resp_body) == "hello"
    assert {:ok, false} = waiter?(intake)
    assert {:refused, :no_waiter} = Intake.deliver(intake, "work", "s1", "again")
    assert {:ok, false} = Intake.waiter?(intake, "work", "s2")
  end

  test "at its deadline the response ends with no text", %{start: start} do
    intake = start.(waiter_deadline: 50)
    conn = post(intake, @stop, path: "/hooks/work/waiter")
    assert {conn.status, String.trim(conn.resp_body)} == {200, ""}
    assert {:ok, false} = waiter?(intake)
  end

  test "a body that names no session is refused, and no event is stored",
       %{db: db, start: start} do
    intake = start.([])
    assert post(intake, "{}", path: "/hooks/work/waiter").status == 400
    assert post(intake, @stop, path: "/hooks/work/other").status == 404
    assert rows(db) == []
  end

  # F-157: every Stop starts a waiter, a blocked one too, so a session has several live.
  test "a newer waiter is the session's, and the older one is answered empty", %{start: start} do
    intake = start.([])
    {first, _, ref1} = stand_in(intake)
    {second, key2, ref2} = stand_in(intake)
    assert_receive {:got, ^first, {^ref1, :release}}, 5_000

    task = Task.async(fn -> Intake.deliver(intake, "work", "s1", "one") end)
    assert_receive {:got, ^second, {^ref2, {:decision, "one"}}}, 5_000
    Intake.written(intake, key2, ref2)
    assert {:ok, :sent} = Task.await(task)
    refute_received {:got, ^first, {_, {:decision, _}}}
    assert {:ok, false} = waiter?(intake)
  end

  test "a waiter with text in flight is kept; a newer one waits behind it, then takes over",
       %{start: start} do
    intake = start.([])
    {first, key1, ref1} = stand_in(intake)
    task = Task.async(fn -> Intake.deliver(intake, "work", "s1", "one") end)
    assert_receive {:got, ^first, {^ref1, {:decision, "one"}}}, 5_000

    {second, _, ref2} = stand_in(intake)
    {third, _, ref3} = stand_in(intake)
    # Of the two behind, the older is answered empty; the first's text is not touched.
    assert_receive {:got, ^second, {^ref2, :release}}, 5_000
    assert {:refused, :no_waiter} = Intake.deliver(intake, "work", "s1", "two")
    Intake.written(intake, key1, ref1)
    assert {:ok, :sent} = Task.await(task)

    task = Task.async(fn -> Intake.deliver(intake, "work", "s1", "two") end)
    assert_receive {:got, ^third, {^ref3, {:decision, "two"}}}, 5_000
    send(third, {:stop})
    assert {:unknown, {:request_closed, _}} = Task.await(task)
  end

  # F-123's new-3: Mailbox tries a due row on the cue of the session's waiter coming and going.
  test "a session's waiter coming and going is cued on its own topic", %{start: start} do
    intake = start.([])
    waiters = %{topic: "intake:h:work:waiters", ids: ["s1"]}
    {_first, _, _} = stand_in(intake)
    assert_receive ^waiters, 5_000
    # A newer one takes the session's place: a cue.
    {second, key2, ref2} = stand_in(intake)
    assert_receive ^waiters, 5_000

    task = Task.async(fn -> Intake.deliver(intake, "work", "s1", "one") end)
    assert_receive {:got, ^second, {^ref2, {:decision, "one"}}}, 5_000
    Intake.written(intake, key2, ref2)
    assert {:ok, :sent} = Task.await(task)
    assert_receive ^waiters, 5_000
    assert {:ok, false} = waiter?(intake)
  end

  test "a failed write ends the hold: unknown while text is in flight", %{start: start} do
    intake = start.([])
    {_first, key1, ref1} = stand_in(intake)
    task = Task.async(fn -> Intake.deliver(intake, "work", "s1", "text") end)
    assert_receive {:got, _, {^ref1, {:decision, "text"}}}, 5_000

    # The text's own write fails: it may have been read, so it is unknown, never sent again.
    Intake.closed(intake, key1, ref1)
    assert {:unknown, {:request_closed, :closed}} = Task.await(task)
    assert {:ok, false} = waiter?(intake)
  end

  test "a failed heartbeat ends the session's waiter, and the session has none",
       %{start: start} do
    intake = start.([])
    {_first, key1, ref1} = stand_in(intake)
    Intake.closed(intake, key1, ref1)
    assert {:ok, false} = await_waiter(intake, false)
  end

  test "a restart lets the waiter go, and the session has none", %{start: start} do
    intake = start.([])
    task = Task.async(fn -> post(intake, @stop, path: "/hooks/work/waiter") end)
    assert {:ok, true} = await_waiter(intake, true)
    stop_supervised!(Intake)
    assert %{status: 200} = Task.await(task)
    intake = start.([])
    assert {:ok, false} = waiter?(intake)
  end

  describe "over a real socket" do
    setup %{start: start} do
      # 20 ms heartbeats, so a closed connection is found within a test.
      intake = start.(beat: 20)
      plug = {Intake.Plug, intake: intake, secret: secret()}

      server =
        start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      {:ok, intake: intake, port: port}
    end

    defp open(port) do
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

      request =
        "POST /hooks/work/waiter HTTP/1.1\r\nhost: 127.0.0.1\r\nx-caf-secret: #{secret()}\r\n" <>
          "content-type: application/json\r\ncontent-length: #{byte_size(@stop)}\r\n\r\n#{@stop}"

      :ok = :gen_tcp.send(socket, request)
      socket
    end

    # Reads from the socket until `text` has arrived.
    defp read_until(socket, text, got \\ "") do
      if String.contains?(got, text) do
        got
      else
        {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
        read_until(socket, text, got <> more)
      end
    end

    test "status 200 at once, heartbeats, then the text", %{intake: intake, port: port} do
      socket = open(port)
      head = read_until(socket, "\r\n\r\n")
      assert head =~ "HTTP/1.1 200"
      assert head =~ "transfer-encoding: chunked"
      # Two heartbeats, each a chunk of one newline.
      read_until(socket, "1\r\n\n\r\n1\r\n\n\r\n")
      assert {:ok, :sent} = Intake.deliver(intake, "work", "s1", "wake up")
      assert read_until(socket, "0\r\n\r\n") =~ "wake up"
      :gen_tcp.close(socket)
    end

    test "a connection closed unseen is found by a heartbeat, and the next waiter takes over",
         %{intake: intake, port: port} do
      first = open(port)
      assert {:ok, true} = await_waiter(intake, true)
      :gen_tcp.close(first)
      second = open(port)
      read_until(second, "\r\n\r\n")

      # Once the first's heartbeat fails, text goes to the second.
      {:ok, :sent} =
        await(fn ->
          case Intake.deliver(intake, "work", "s1", "to the second") do
            {:ok, :sent} -> {:ok, :sent}
            other -> other
          end
        end)

      assert read_until(second, "0\r\n\r\n") =~ "to the second"
      :gen_tcp.close(second)
    end
  end

  describe "the hook program" do
    setup %{start: start, dir: dir} do
      # Long and random: the test looks for it in every process's arguments, and a short one
      # (`t72`) matched another program's.
      secret = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      intake = start.(beat: 20, waiter_deadline: 2_000)
      plug = {Intake.Plug, intake: intake, secret: secret}

      server =
        start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      input = Path.join(dir, "input.json")
      File.write!(input, @stop)
      paths = %{sh: program!(:sh), curl: program!(:curl)}
      {:ok, intake: intake, port: port, secret: secret, input: input, paths: paths}
    end

    # Runs the hook's command as Claude Code does, the input on stdin; stderr to a file.
    defp run_hook(command, input, dir) do
      err = Path.join(dir, "stderr-#{System.unique_integer([:positive])}")
      script = ~s(eval "$1" < "$2" 2> "$3")

      Task.async(fn ->
        port =
          Port.open({:spawn_executable, program!(:sh)}, [
            :binary,
            :exit_status,
            args: ["-c", script, "sh", command, input, err]
          ])

        receive do
          {^port, {:exit_status, status}} -> {status, File.read!(err)}
        after
          10_000 -> {:timeout, File.read(err)}
        end
      end)
    end

    defp command(c, secret \\ nil) do
      {:ok, hooks} = Intake.waiter_hook(c.port, "work", secret || c.secret, c.paths)
      [%{"hooks" => [%{"command" => command}]}] = hooks["Stop"]
      command
    end

    test "text wakes the session: stderr and exit 2", %{dir: dir} = c do
      task = run_hook(command(c), c.input, dir)
      assert {:ok, true} = await_waiter(c.intake, true)
      assert {:ok, :sent} = Intake.deliver(c.intake, "work", "s1", "a report is due")
      assert Task.await(task, 15_000) == {2, "a report is due\n"}
    end

    test "the secret is in no process's arguments while it waits", %{dir: dir} = c do
      task = run_hook(command(c), c.input, dir)
      assert {:ok, true} = await_waiter(c.intake, true)
      {ps, 0} = System.cmd(program!(:ps), ["-ww", "-A", "-o", "command="])
      assert ps =~ "caf-waiter"
      refute ps =~ c.secret
      assert {:ok, :sent} = Intake.deliver(c.intake, "work", "s1", "done")
      assert {2, _} = Task.await(task, 15_000)
    end

    test "the deadline, and a wrong secret, exit 0 with nothing on stderr", %{dir: dir} = c do
      assert Task.await(run_hook(command(c, "wrong"), c.input, dir), 15_000) == {0, ""}
      assert Task.await(run_hook(command(c), c.input, dir), 15_000) == {0, ""}
    end
  end
end
