defmodule CodingAgentFramework.HeadlessStandIn do
  @moduledoc """
  A stand-in for Claude Code in `-p` stream-json mode, so no test starts the real one. It is a
  bash script run by `ClaudeCLI.wrapper/4` under dtach. It reads stream-json lines on stdin and
  writes events on stdout in the shapes `docs/build-notes/F-31.md` records, with synthetic values:

  - `system`/`init` with the `--session-id` or `--resume` id: on the first line it reads
    (`:on_message`, the default: Claude Code 2.1.322 writes it only then, F-152), at its start
    (`:at_start`, only for a test that needs it so and says why), or never (`:never`);
  - for a user line: its replay (`isReplay` and its uuid), then `assistant`, a
    `rate_limit_event` and a `result` naming the uuid, whose text is `done <uuid>`. A message
    whose text starts with `ask` (after a `From <name> (<kind>): ` sender line, F-170) first asks a `can_use_tool` permission (`request_id`
    `req-<uuid>`), and ends its turn when the answer comes; so does every message while a file
    `<dir>/hold` exists; the answer is replayed. `half` ends its turn with half a
    `rate_limit_event` line, and the next message finishes it; `self` ends its turn, then
    starts one of its own at once, whose `result` (`on its own`, uuid `r-self-<uuid>`) names no message; `quiet`
    ends its turn with an empty `result` that names no message, so no report is read from it;
  - for `interrupt`: a cancel of the request pending, and a `result`;
  - `end_session` ends it; a line that is not a JSON object ends it with status 1.

  It records each line it takes in `<dir>/taken` (`message <uuid>`, `answer <id>`, `interrupt`,
  `end`, `invalid`), its arguments in `<dir>/argv/<session id>`, and its pid in `<dir>/pids/`, so a test ends what it started by pid; it
  exits at once if that directory was already ended (`TestHost.end_recorded/2`). It ends after
  `idle` seconds with no input (`TestHost.stand_in_idle/0` by default), so no run leaves it for
  long.
  """

  import CodingAgentFramework.TestHost, only: [program!: 1, kill: 1, stand_in_idle: 0]

  @doc """
  Writes the stand-in for `mode` into `dir` and answers its path. It is written whole under
  another name and renamed into place, since a start may be running the path (F-39).
  """
  def write!(dir, mode \\ :on_message, idle \\ stand_in_idle())
      when mode in [:at_start, :on_message, :never] do
    path = Path.join(dir, "headless-#{mode}")
    File.mkdir_p!(Path.join(dir, "pids"))
    File.mkdir_p!(Path.join(dir, "argv"))
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, script(dir, mode, idle))
    File.chmod!(tmp, 0o755)
    File.rename!(tmp, path)
    path
  end

  @doc "The arguments the stand-in for session `session_id` was started with, or nil."
  def argv(dir, session_id) do
    case File.read(Path.join([dir, "argv", session_id])) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> nil
    end
  end

  @doc "The lines the stand-in started from `dir` took, in order."
  def taken(dir) do
    case File.read(Path.join(dir, "taken")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  @doc """
  Ends every stand-in started from `dir`, by the pid each recorded. A test that started none has
  no `pids` directory, and nothing to end.
  """
  def kill_all(dir) do
    case File.ls(Path.join(dir, "pids")) do
      {:ok, pids} -> Enum.each(pids, &kill/1)
      {:error, :enoent} -> :ok
    end
  end

  defp script(dir, mode, idle) do
    ~S"""
    #!BASH
    if [ "$1 $2" = "auth status" ]; then
      printf '{"loggedIn": true, "authMethod": "stand_in", "loginExpiresAt": null}\n'; exit 0
    fi
    sid='' args=("$@")
    while [ $# -gt 0 ]; do
      case $1 in --session-id|--resume) sid=$2; shift 2 ;; *) shift ;; esac
    done
    : 2>/dev/null > "DIR/pids/$$" || exit 0
    [ -n "$sid" ] && printf '%s\n' "${args[@]}" > "DIR/argv/$sid"
    rec() { printf '%s\n' "$1" >> "DIR/taken"; }
    ev() { printf '%s\n' "$1"; }
    field() { [[ $line =~ \"$1\":\"([^\"]*)\" ]] && printf '%s' "${BASH_REMATCH[1]}"; }
    turn_end() {
      ev '{"type":"assistant","session_id":"'"$sid"'","uuid":"a-'"$1"'","message":{"content":[]}}'
      ev '{"type":"rate_limit_event","session_id":"'"$sid"'","rate_limit_info":{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":0.25,"resetsAt":1900000000}}}}'
      ev '{"type":"result","subtype":"'"${2:-success}"'","is_error":false,"result":"done '"$1"'","session_id":"'"$sid"'","uuid":"r-'"$1"'","user_message_uuids":["'"$1"'"]}'
    }
    init() { ev '{"type":"system","subtype":"init","session_id":"'"$sid"'","uuid":"init"}'; }
    mode=MODE
    [ $mode = at_start ] && init
    pending='' asker='' half=''
    while IFS= read -r -t IDLE line; do
      [ -z "$line" ] && continue
      [ $mode = on_message ] && { init; mode=done; }
      case $line in \{*\}) ;; *) rec invalid; exit 1 ;; esac
      case $line in
        *'"type":"user"'*)
          u=$(field uuid); rec "message $u"
          if [ -n "$half" ]; then printf '"utilization":0.5}}\n'; half=''; fi
          ev '{"type":"user","isReplay":true,"session_id":"'"$sid"'","uuid":"'"$u"'","message":{"role":"user","content":""}}'
          [ -e "DIR/hold" ] && line='"content":"ask'
          case $line in
            *'"content":"ask'*|*'"content":"From '*'): ask'*)
              pending="req-$u" asker=$u
              ev '{"type":"control_request","request_id":"'"$pending"'","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"true"},"tool_use_id":"tu-'"$u"'"}}' ;;
            *'"content":"self'*|*'"content":"From '*'): self'*)
              turn_end "$u"
              ev '{"type":"result","subtype":"success","is_error":false,"result":"on its own","session_id":"'"$sid"'","uuid":"r-self-'"$u"'","user_message_uuids":[]}' ;;
            *'"content":"quiet'*|*'"content":"From '*'): quiet'*)
              ev '{"type":"result","subtype":"success","is_error":false,"result":"","session_id":"'"$sid"'","uuid":"r-quiet-'"$u"'","user_message_uuids":[]}' ;;
            *'"content":"half'*|*'"content":"From '*'): half'*)
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
    |> String.replace("IDLE", Integer.to_string(idle))
  end
end
