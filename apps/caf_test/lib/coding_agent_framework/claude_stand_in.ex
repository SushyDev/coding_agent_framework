defmodule CodingAgentFramework.ClaudeStandIn do
  @moduledoc """
  A stand-in for Claude Code, so no test starts the real one. It is a bash script, started with
  `ClaudeCLI`'s argv and environment, that:

  - writes `<CLAUDE_CONFIG_DIR>/sessions/<pid>.json` in the shape `Registry` reads, with
    synthetic values: its pid, `sessionId` (the `--resume` id, or one made up), `name` (from
    `--name`), `cwd`, `procStart` as `ps` prints it, and `status`: `idle`, or `busy` from the
    line `busy` until the line `idle`, as a turn runs. The file is written whole and renamed,
    and removed when the stand-in exits;
  - exits 143 on SIGTERM, as Claude Code does (F-114), unless it read the line `deaf`, after
    which it ignores SIGTERM, as a process that does not end would;
  - echoes each line of its input, and exits on `/exit`, or after `idle` seconds with none
    (`TestHost.stand_in_idle/0` by default), so no run leaves it for long;
  - records its pid in `<dir>/pids/`, so a test ends what it started by pid (`kill_all/1`,
    `TestHost.end_recorded/2`), and exits at once if that directory was already ended.

  When it writes its file is the `mode`: `:at_start`, `:on_go` (when it reads the line `go`) or
  `:never`.
  """

  import CodingAgentFramework.TestHost, only: [program!: 1, kill: 1, stand_in_idle: 0]

  @doc """
  Writes the stand-in for `mode` into `dir` and answers its path. The script is written whole
  under another name and renamed into place, as the stand-in writes its own file: a start may
  be running the path at that moment, and a script rewritten in place is empty in between, so
  that start ran nothing and exited at once (F-39).
  """
  def write!(dir, mode, idle \\ stand_in_idle()) when mode in [:at_start, :on_go, :never] do
    path = Path.join(dir, "claude-#{mode}")
    File.mkdir_p!(Path.join(dir, "pids"))
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, script(Path.join(dir, "pids"), mode, idle))
    File.chmod!(tmp, 0o755)
    File.rename!(tmp, path)
    path
  end

  @doc "Ends every stand-in started from `dir`, by the pid each recorded."
  def kill_all(dir) do
    # A test that started no stand-in has no `pids` directory, and nothing to end.
    case File.ls(Path.join(dir, "pids")) do
      {:ok, pids} -> Enum.each(pids, &kill/1)
      {:error, :enoent} -> :ok
    end
  end

  defp script(pids, mode, idle) do
    ~s"""
    #!#{program!(:bash)}
    name='' resume=''
    while [ $# -gt 0 ]; do
      case $1 in
        --name) name=$2; shift 2 ;;
        --resume) resume=$2; shift 2 ;;
        --) break ;;
        *) shift ;;
      esac
    done
    : 2>/dev/null > "#{pids}/$$" || exit 0
    file="$CLAUDE_CONFIG_DIR/sessions/$$.json"
    status=idle announced=''
    announce() {
      start=$(LC_ALL=C TZ=UTC #{program!(:ps)} -o lstart= -p $$)
      start=${start#"${start%%[![:space:]]*}"}
      start=${start%"${start##*[![:space:]]}"}
      printf '{"pid": %d, "sessionId": "%s", "name": "%s", "cwd": "%s", "procStart": "%s", "status": "%s"}' \\
        $$ "${resume:-stand-in-$$}" "$name" "$PWD" "$start" "$status" > "$file.tmp"
      #{program!(:mv)} -f "$file.tmp" "$file"
      announced=1
    }
    trap '#{program!(:rm)} -f "$file"' EXIT
    trap 'exit 143' TERM
    mode=#{mode}
    [ $mode = at_start ] && announce
    while IFS= read -r -t #{idle} line; do
      printf 'got: %s\\n' "$line"
      case $line in
        /exit) exit 0 ;;
        go) [ $mode = on_go ] && announce ;;
        busy|idle) status=$line; [ -n "$announced" ] && announce ;;
        deaf) trap '' TERM ;;
      esac
    done
    """
  end
end
