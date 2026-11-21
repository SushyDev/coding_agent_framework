defmodule CodingAgentFramework.Sessions.Turn do
  @moduledoc """
  A session's turn state, one function per kind of session, from the evidence its caller read
  (`docs/design.md`, "A session's life"). A pure module: it reads nothing itself, so `Mailbox`,
  the `Tracker` and `Sessions` judge one turn by one rule, each over what it has read.

  - **A headless session** (`headless/2`): `Stream`'s fold of its event log. The log is written
    in order and a `result` closes a turn, so one read of the fold decides. A background command
    of its own that still runs (the fold's `tasks`) keeps it `:running` after its `result`: the
    command's end wakes it (F-171).
  - **An interactive session** (`interactive/3`): its session file's `status`, as `Registry`
    reads it, and whether `Intake` holds its waiter (`Intake.waiter?/4`). The file alone is one
    read, and one read is never the only sign that a turn has ended when it decides a write
    (F-113's new-2): only the two together are `:ended`. The file alone that reads idle is
    `:idle`, which a write must check again by a second reading of its own (R8's box check).

  The states:

  - `:ended`: the turn has ended, by evidence enough to decide a write into the session;
  - `:idle`: an interactive session's file reads idle, and nothing else says so;
  - `:running`: a turn runs;
  - `:waiting`: a turn waits on a person (a held `can_use_tool` request, the file's `waiting`);
  - `:ending`: a headless session's `end_session` was written;
  - `:gone`: the process the evidence names is gone;
  - `:dialog`: an interactive session's row waits on a dialog its pane shows (`status`
    `dialog`, F-140): a person or the app answers it, and it is never idle (F-180);
  - `:limited`: the row's last turn ended at a usage limit (`Sessions.Agents.limit/1`, F-185):
    never idle, never stuck and never an ended turn, until a turn of it runs after the limit
    and the row says so. `Mailbox` reads its turn as for any row once the limit's reset passed
    (`Sessions.Agents.held?/2`), so the word to go on goes into an ended turn;
  - `:not_running`: the agent row is not `running`, so no turn is read;
  - `:unread`: nothing read names the session's process yet.

      iex> alias CodingAgentFramework.Sessions.Turn
      iex> row = %{status: "running", role: "parent", pid: 7, proc_start: "Tue Nov 17 09:00:00 2026"}
      iex> files = [%{pid: 7, proc_start: "Tue Nov 17  09:00:00 2026", alive: :live, status: "idle"}]
      iex> Turn.interactive(row, files, true)
      :ended
      iex> Turn.interactive(row, files, false)
      :idle
      iex> Turn.headless(%{status: "running", role: "delegate"}, %{idle: false, gone: false})
      :running
  """

  alias CodingAgentFramework.Holder
  alias CodingAgentFramework.Sessions.Agents

  @type t ::
          :ended
          | :idle
          | :running
          | :waiting
          | :ending
          | :gone
          | :dialog
          | :limited
          | :not_running
          | :unread

  @doc """
  The turn state of `row` by its kind: `headless/2` with `evidence.fold` for a headless
  session, `interactive/3` with `evidence.files` and `evidence.waiter` for the others.
  """
  @spec of(map, map) :: t
  def of(row, evidence) do
    if Agents.headless?(row),
      do: headless(row, evidence[:fold]),
      else: interactive(row, evidence[:files] || [], Map.get(evidence, :waiter, :unread))
  end

  @doc """
  A headless session's turn: `:not_running` unless its row is `running`, `:limited` while it
  is; then `stream/1` of its `Stream` fold (nil when `Stream` follows none).
  """
  @spec headless(map, map | nil) :: t
  def headless(row, fold) do
    cond do
      not Agents.running?(row) -> :not_running
      Agents.limit(row) -> :limited
      true -> stream(fold)
    end
  end

  @doc """
  What a `Stream` fold alone says of the turn, whatever the row: `:unread` with no fold,
  `:gone`, `:ending`, `:ended` once the turn's `result` was read and no background command of
  its own runs, `:waiting` while a `can_use_tool` request is held, else `:running`. A fold as
  the `Tracker`'s view holds it is read the same way.

      iex> CodingAgentFramework.Sessions.Turn.stream(%{idle: true, gone: false, ending: false})
      :ended
      iex> CodingAgentFramework.Sessions.Turn.stream(%{idle: true, tasks: %{"b1" => %{}}})
      :running
  """
  @spec stream(map | nil) :: t
  def stream(nil), do: :unread

  def stream(%{} = fold) do
    cond do
      fold[:gone] == true -> :gone
      fold[:ending] == true -> :ending
      fold[:idle] == true and Enum.empty?(fold[:tasks] || %{}) -> :ended
      held?(fold[:requests]) -> :waiting
      true -> :running
    end
  end

  defp held?(%{} = requests), do: Enum.any?(requests, &match?({_, %{state: :held}}, &1))
  defp held?(_), do: false

  @doc """
  An interactive session's turn: `:dialog` while its row waits on a dialog, `:not_running` for
  any other row that is not `running`, `:limited` while it is; then its session file among `files` (`file/2`) and
  `waiter`, `true` when `Intake` holds the session's waiter,
  `false` when it does not, `:unread` when it was not read. Only a file that reads idle with a
  waiter held is `:ended`; a waiter held while the file reads busy is a turn a person's prompt
  started, `:running`.

      iex> CodingAgentFramework.Sessions.Turn.interactive(%{status: "dialog"}, [], false)
      :dialog
  """
  @spec interactive(map, [map], boolean | :unread) :: t
  def interactive(row, files, waiter) do
    cond do
      Agents.running?(row) and Agents.limit(row) != nil ->
        :limited

      Agents.running?(row) ->
        case file_state(file(row, files)) do
          :idle when waiter == true -> :ended
          state -> state
        end

      # No session file exists while a startup dialog is shown, so the row is the evidence.
      row[:status] == "dialog" ->
        :dialog

      true ->
        :not_running
    end
  end

  @doc """
  What a session file alone says of the turn: `:running` (`busy`, or `shell`: the turn ended
  and a background command of it still runs, measured on Claude Code 2.1.322), `:waiting`,
  `:idle`, `:gone` for a file whose process is not live, `:unread` with no file or a status
  this build does not know (the field is not documented, and is checked per release).
  """
  @spec file_state(map | nil) :: t
  def file_state(%{alive: :live, status: "busy"}), do: :running
  def file_state(%{alive: :live, status: "shell"}), do: :running
  def file_state(%{alive: :live, status: "waiting"}), do: :waiting
  def file_state(%{alive: :live, status: "idle"}), do: :idle
  def file_state(%{alive: alive}) when alive in [:gone, :replaced], do: :gone
  def file_state(_), do: :unread

  @doc """
  The session file among `files` (`Registry`'s rows) that names `row`'s process: its pid and
  its start time, compared with spaces made single. Nil when none does.
  """
  @spec file(map, [map]) :: map | nil
  def file(%{pid: pid} = row, files) when is_integer(pid) do
    start = Holder.Process.normal(row[:proc_start] || "")

    Enum.find(files, fn f ->
      f[:pid] == pid and Holder.Process.normal(f[:proc_start] || "") == start
    end)
  end

  def file(_row, _files), do: nil
end
