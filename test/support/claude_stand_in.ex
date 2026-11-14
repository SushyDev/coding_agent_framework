defmodule CodingAgentFramework.ClaudeStandIn do
  @moduledoc """
  A stand-in for Claude Code, so no test starts the real one. It is a bash script, started with
  `ClaudeCLI`'s argv and environment, that:

  - writes `<CLAUDE_CONFIG_DIR>/sessions/<pid>.json` in the shape `Registry` reads, with
    synthetic values: its pid, `sessionId` (the `--resume` id, or one made up), `name` (from
    `--name`), `cwd` and `procStart` as `ps` prints it. The file is written whole and renamed,
    and removed when the stand-in exits;
  - echoes each line of its input, and exits on `/exit`;
  - records its pid in `<dir>/pids/`, so a test ends what it started by pid (`kill_all/1`).

  When it writes its file is the `mode`: `:at_start`, `:on_go` (when it reads the line `go`) or
  `:never`.
  """

  import CodingAgentFramework.TestHost, only: [program!: 1, kill: 1]

  @doc "Writes the stand-in for `mode` into `dir` and answers its path."
  def write!(dir, mode) when mode in [:at_start, :on_go, :never] do
    path = Path.join(dir, "claude-#{mode}")
    File.mkdir_p!(Path.join(dir, "pids"))
    File.write!(path, script(Path.join(dir, "pids"), mode))
    File.chmod!(path, 0o755)
    path
  end

  @doc "Ends every stand-in started from `dir`, by the pid each recorded."
  def kill_all(dir) do
    for pid <- File.ls!(Path.join(dir, "pids")), do: kill(pid)
    :ok
  end

  defp script(pids, mode) do
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
    : > "#{pids}/$$"
    file="$CLAUDE_CONFIG_DIR/sessions/$$.json"
    announce() {
      start=$(LC_ALL=C TZ=UTC #{program!(:ps)} -o lstart= -p $$)
      start=${start#"${start%%[![:space:]]*}"}
      start=${start%"${start##*[![:space:]]}"}
      printf '{"pid": %d, "sessionId": "%s", "name": "%s", "cwd": "%s", "procStart": "%s"}' \\
        $$ "${resume:-stand-in-$$}" "$name" "$PWD" "$start" > "$file.tmp"
      #{program!(:mv)} -f "$file.tmp" "$file"
    }
    trap '#{program!(:rm)} -f "$file"' EXIT
    mode=#{mode}
    [ $mode = at_start ] && announce
    while IFS= read -r line; do
      printf 'got: %s\\n' "$line"
      case $line in
        /exit) exit 0 ;;
        go) [ $mode = on_go ] && announce ;;
      esac
    done
    """
  end
end
