defmodule CodingAgentFramework.HeadlessStandIn do
  @moduledoc """
  A stand-in for Claude Code in `-p` stream-json mode, so no test starts the real one. It is a
  bash script run by `ClaudeCLI.wrapper/4` under dtach. It reads stream-json lines on stdin and
  writes events on stdout in the shapes `docs/build-notes/F-31.md` records, with synthetic values:

  - `system`/`init` with the `--session-id` or `--resume` id: at its start (mode `:at_start`),
    on the first line it reads (`:on_message`), or never (`:never`);
  - for a user line: its replay (`isReplay` and its uuid), then `assistant`, a
    `rate_limit_event` and a `result` naming the uuid. A message whose text starts with `ask`
    first asks a `can_use_tool` permission (`request_id` `req-<uuid>`), and ends its turn when
    the answer comes; the answer is replayed. `half` ends its turn with half a
    `rate_limit_event` line, and the next message finishes it;
  - for `interrupt`: a cancel of the request pending, and a `result`;
  - `end_session` ends it; a line that is not a JSON object ends it with status 1.

  It records each line it takes in `<dir>/taken` (`message <uuid>`, `answer <id>`, `interrupt`,
  `end`, `invalid`) and its pid in `<dir>/pids/`, so a test ends what it started by pid.
  """

  import CodingAgentFramework.TestHost, only: [program!: 1, kill: 1]

  @doc """
  Writes the stand-in for `mode` into `dir` and answers its path. It is written whole under
  another name and renamed into place, since a start may be running the path (F-39).
  """
  def write!(dir, mode \\ :at_start) when mode in [:at_start, :on_message, :never] do
    path = Path.join(dir, "headless-#{mode}")
    File.mkdir_p!(Path.join(dir, "pids"))
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, script(dir, mode))
    File.chmod!(tmp, 0o755)
    File.rename!(tmp, path)
    path
  end

  @doc "The lines the stand-in started from `dir` took, in order."
  def taken(dir) do
    case File.read(Path.join(dir, "taken")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  @doc "Ends every stand-in started from `dir`, by the pid each recorded."
  def kill_all(dir) do
    for pid <- File.ls!(Path.join(dir, "pids")), do: kill(pid)
    :ok
  end

  defp script(dir, mode) do
    ~S"""
    #!BASH
    sid=''
    while [ $# -gt 0 ]; do
      case $1 in --session-id|--resume) sid=$2; shift 2 ;; *) shift ;; esac
    done
    : > "DIR/pids/$$"
    rec() { printf '%s\n' "$1" >> "DIR/taken"; }
    ev() { printf '%s\n' "$1"; }
    field() { [[ $line =~ \"$1\":\"([^\"]*)\" ]] && printf '%s' "${BASH_REMATCH[1]}"; }
    turn_end() {
      ev '{"type":"assistant","session_id":"'"$sid"'","uuid":"a-'"$1"'","message":{"content":[]}}'
      ev '{"type":"rate_limit_event","session_id":"'"$sid"'","rate_limit_info":{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":0.25,"resetsAt":1900000000}}}}'
      ev '{"type":"result","subtype":"'"${2:-success}"'","is_error":false,"session_id":"'"$sid"'","user_message_uuids":["'"$1"'"]}'
    }
    init() { ev '{"type":"system","subtype":"init","session_id":"'"$sid"'","uuid":"init"}'; }
    mode=MODE
    [ $mode = at_start ] && init
    pending='' asker='' half=''
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      [ $mode = on_message ] && { init; mode=done; }
      case $line in \{*\}) ;; *) rec invalid; exit 1 ;; esac
      case $line in
        *'"type":"user"'*)
          u=$(field uuid); rec "message $u"
          if [ -n "$half" ]; then printf '"utilization":0.5}}\n'; half=''; fi
          ev '{"type":"user","isReplay":true,"session_id":"'"$sid"'","uuid":"'"$u"'","message":{"role":"user","content":""}}'
          case $line in
            *'"content":"ask'*)
              pending="req-$u" asker=$u
              ev '{"type":"control_request","request_id":"'"$pending"'","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"true"},"tool_use_id":"tu-'"$u"'"}}' ;;
            *'"content":"half'*)
              turn_end "$u"; half=1
              printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed",' ;;
            *) turn_end "$u" ;;
          esac ;;
        *'"type":"control_response"'*)
          id=$(field request_id); rec "answer $id"
          if [ "$id" = "$pending" ]; then
            ev '{"type":"control_response","isReplay":true,"response":{"subtype":"success","request_id":"'"$id"'"}}'
            pending=''; turn_end "$asker"
          fi ;;
        *'"subtype":"interrupt"'*)
          rec interrupt
          if [ -n "$pending" ]; then
            ev '{"type":"control_cancel_request","request_id":"'"$pending"'"}'
            pending=''; turn_end "$asker" error_during_execution
          fi ;;
        *'"subtype":"end_session"'*) rec end; exit 0 ;;
      esac
    done
    """
    |> String.replace("BASH", program!(:bash), global: false)
    |> String.replace("DIR", dir)
    |> String.replace("MODE", Atom.to_string(mode))
  end
end
