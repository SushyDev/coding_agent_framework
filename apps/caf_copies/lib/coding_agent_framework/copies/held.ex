defmodule CodingAgentFramework.Copies.Held do
  @moduledoc """
  The steps a program held on a host takes in a copy, shared by `Jobs` and `Services` (see
  "Hosts" in `docs/design.md` and `model/tla/Copy.tla`): the copy's turn and sync
  (`CodingAgentFramework.Copies`), the host's directory, the hold under dtach of a small
  wrapper with its record (`CodingAgentFramework.Holder.Process`), and the start's settle, after which the turn goes
  back. Pure functions over a context; each call works in its caller's process.

  What the program is, how its host is read and what its row says stay with the caller: the
  settle takes a `read` and a `write` function.

    * `read.(:reply)` is what dtach's held reply means (a job is live; a service reads its pid);
    * `read.(:cut)` is a read of the host once the start's deadline has passed, since a start
      whose reply was cut may still land until then;
    * `write.(seen)` writes the row for `{:ok, seen}` or `{:refused, {:start, reason}}`, and
      answers the call.

  A read that answers `{:unknown, _}` leaves the turn held and the row as it is, for a later
  settle (`settle_cut/4`). So does a write that answers `{:unknown, _}`: the row still says the
  start is under way.

      {:ok, ctx} = Held.context(%{hosts: hosts, copies: copies},
        %{host: "box", project: "web", copy: "fix-login", kind: "jobs", name: "j7", run: "j7"}, 5_000)
      {:ok, %{record: _}} = Held.ready(ctx, worktree, [sync_timeout: 60_000], &mark_refused/1)
      reply = Held.hold(ctx, wrapper, ["caf-job", ctx.path], argv, [])
      Held.settle(ctx, reply, until, read, write)
  """

  alias CodingAgentFramework.{Copies, Holder, Shell}

  @call 5_000
  # $1 mkdir, $2 rm, $3 the directory; then files an earlier start of the name left.
  @prepare ~S"""
  m=$1 r=$2 d=$3; shift 3
  "$m" -p "$d" || exit 1
  [ "$#" -eq 0 ] || "$r" -f -- "$@"
  """

  @type ctx :: map
  @type where :: %{
          host: String.t(),
          project: String.t(),
          copy: String.t(),
          kind: String.t(),
          name: String.t(),
          run: String.t()
        }

  @doc """
  The context of the program `where` names: its host's programs, its copy and the copy's path,
  a `Holder` of `<dir>/<kind>` on the host whose shell runs wait `timeout` ms and its records
  (`procs`, a `Holder.Process`; the host's programs then name ps, kill and sleep), `dir` and `base`
  (`<dir>/<kind>/<name>`, for the caller's own files). `config` holds `:hosts`, each host's
  name to `%{programs: programs, dir: dir}`, and `:copies`, the `Copies` server. `run` names
  the copy's turn; `name` the socket.

      iex> {:refused, {:no_host, "box"}} =
      ...>   CodingAgentFramework.Copies.Held.context(%{hosts: %{}, copies: nil},
      ...>     %{host: "box", project: "p", copy: "w", kind: "jobs", name: "j", run: "j"}, 1_000)
  """
  @spec context(map, where, timeout :: pos_integer) :: {:ok, ctx} | {:refused, term}
  def context(%{hosts: hosts, copies: copies}, where, timeout) do
    with {:ok, %{programs: programs, dir: dir}} <- host(hosts, where.host),
         copy = %{programs: programs, dir: dir, project: where.project, name: where.copy},
         {:ok, {path, _lock}} <- Copies.place(copy),
         kind_dir = Path.join(dir, where.kind),
         {:ok, holder} <- Holder.new(programs, kind_dir, timeout: timeout),
         {:ok, procs} <- Holder.Process.new(programs, holder) do
      {:ok,
       %{
         copies: copies,
         copy: copy,
         programs: programs,
         holder: holder,
         procs: procs,
         path: path,
         dir: kind_dir,
         base: Path.join(kind_dir, where.name),
         name: where.name,
         run: where.run
       }}
    end
  end

  defp host(hosts, name) do
    case Map.fetch(hosts, name) do
      {:ok, host} -> {:ok, host}
      :error -> {:refused, {:no_host, name}}
    end
  end

  @doc """
  Takes the copy's turn, syncs it from `worktree`, makes the program's directory on the host
  and removes the files named in `:clear`, then marks the start as being sent. Answers the
  sync's `{:ok, %{record: record, files: n}}`. Each refusal of the take, the sync or the
  directory is handed to `refused` first, which marks the caller's row; a refused directory
  gives the turn back. Options: `:sync_timeout` (60 s), `:lock_wait` (30 s), `:reaper` and
  `:fetch` for the sync; `:clear`, paths on the host.
  """
  @spec ready(ctx, String.t(), keyword, (term -> term)) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def ready(ctx, worktree, opts, refused) do
    sync_opts = copy_opts(opts) ++ [fetch: Keyword.get(opts, :fetch, [])]

    with {:ok, :taken} <- refuse(refused, Copies.take(ctx.copies, ctx.copy, ctx.run)),
         {:ok, synced} <-
           refuse(refused, Copies.sync(ctx.copies, ctx.copy, ctx.run, worktree, sync_opts)),
         :ok <- prepare(ctx, Keyword.get(opts, :clear, []), refused),
         :ok <- Copies.starting(ctx.copies, ctx.copy, ctx.run),
         do: {:ok, synced}
  end

  @doc """
  The options of an rsync of the copy, from a caller's: `:sync_timeout` as `:timeout`,
  `:lock_wait` and `:reaper`.

      iex> CodingAgentFramework.Copies.Held.copy_opts(sync_timeout: 1_000)
      [timeout: 1_000, lock_wait: 30_000]
  """
  @spec copy_opts(keyword) :: keyword
  def copy_opts(opts) do
    [
      timeout: Keyword.get(opts, :sync_timeout, 60_000),
      lock_wait: Keyword.get(opts, :lock_wait, 30_000),
      reaper: Keyword.get(opts, :reaper)
    ]
    |> Enum.reject(&is_nil(elem(&1, 1)))
  end

  defp refuse(refused, {:refused, _} = refusal) do
    refused.(refusal)
    refusal
  end

  defp refuse(_refused, other), do: other

  defp prepare(ctx, clear, refused) do
    %{mkdir: mkdir, rm: rm, sh: sh} = ctx.programs.paths
    args = ["-c", @prepare, "caf-prepare", mkdir, rm, ctx.dir | clear]

    case Shell.run(ctx.programs.host, sh, args, timeout: @call) do
      {:ok, %{status: 0}} ->
        :ok

      other ->
        Copies.give_back(ctx.copies, ctx.copy, ctx.run)
        refuse(refused, {:refused, {:host, other}})
    end
  end

  @doc """
  Holds `sh -c script args… argv…` on the context's socket under `Holder.Process.hold/4`, which
  writes the record of its pid and start time first, in the environment `env`, and
  answers dtach's reply as `CodingAgentFramework.Holder.hold/4` does. `args` begins with the
  script's `$0`.
  """
  @spec hold(ctx, String.t(), [String.t()], [String.t()], [{String.t(), String.t()}]) ::
          {:ok, String.t()} | {:refused, term} | {:unknown, term}
  def hold(ctx, script, args, argv, env) do
    wrapper = [ctx.programs.paths.sh, "-c", script | args]
    Holder.Process.hold(ctx.procs, ctx.name, wrapper ++ argv, env: env)
  end

  @doc """
  Settles a start from dtach's `reply`: held, it is what `read.(:reply)` says; refused, nothing
  ran; cut, the host is read with `read.(:cut)` once `until` (ms, OS time) has passed. Then the
  row is written and the turn goes back. Answers what `write` answers, or the read's
  `{:unknown, _}`.
  """
  @spec settle(ctx, term, integer, (atom -> term), (term -> term)) :: term
  def settle(ctx, reply, until, read, write) do
    seen =
      case reply do
        {:ok, _} ->
          read.(:reply)

        {:refused, reason} ->
          {:refused, {:start, reason}}

        {:unknown, _} ->
          pause(until - now())
          read.(:cut)
      end

    write_and_give_back(ctx, seen, write)
  end

  @doc """
  Settles a start whose call ended before its settle, as after a restart: before `until` it
  answers `{:unknown, {:starting_until, until}}`; after it, the host is read with
  `read.(:cut)`, then as `settle/5`.
  """
  @spec settle_cut(ctx, integer, (atom -> term), (term -> term)) :: term
  def settle_cut(ctx, until, read, write) do
    if now() < until,
      do: {:unknown, {:starting_until, until}},
      else: write_and_give_back(ctx, read.(:cut), write)
  end

  defp write_and_give_back(_ctx, {:unknown, _} = unread, _write), do: unread

  defp write_and_give_back(ctx, seen, write) do
    case write.(seen) do
      {:unknown, _} = unwritten ->
        unwritten

      answer ->
        Copies.give_back(ctx.copies, ctx.copy, ctx.run)
        answer
    end
  end

  defp pause(ms) when ms > 0 do
    receive do
    after
      ms -> :ok
    end
  end

  defp pause(_), do: :ok

  defp now, do: System.os_time(:millisecond)
end
