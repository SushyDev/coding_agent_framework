defmodule CodingAgentFramework.ScreenStandIn do
  @moduledoc """
  A stand-in for Claude Code's screen, so no test starts the real one. It is a bash script that
  draws a release's captured fixtures (`apps/caf_screen/test/fixtures/<release>/`), as `Screen`
  reads them, and reads its input one key at a time with no echo:

  - idle, it draws `text-typed`'s screen with the box holding what was typed since the last
    Enter (an empty box is `❯` and a no-break space);
  - at Enter it appends the box's text, as one line, to `<dir>/submitted` (`submitted/2`), and
    runs a turn that ends at once: its session file says `busy`, then `idle`;
  - started with `--screen running`, it draws `turn-running`'s screen until Escape, which ends
    the turn: it writes `<dir>/interrupted` and draws the idle screen;
  - started with `--screen limit_wait`, it draws `usage-limit-wait`'s screen, Claude Code's own
    wait at a usage limit, and takes no key; its session file says `busy`, since what 2.1.322's
    says during the wait was never measured (F-191), so only the screen tells the wait;
  - started with `--screen menu`, or written with `menu: true`, it draws the `menu` fixture's screen (F-198), a menu no rule
    names above the box, its marker on its first option, its session file `idle`. Down and Up
    move the marker; Enter answers its option and a lone Escape `esc`, each written to
    `<dir>/menu` (`menu_answer/1`), and the idle screen is drawn after;
  - `--version` prints the release as Claude Code does (`2.1.322 (Claude Code)`) and exits;
  - the argument after `--` is the start's prompt, run as its first turn: written to
    `<dir>/prompts/<pid>` (`prompts/1`), its session file `busy`, then `idle`;
  - written with `dialogs: [:trust, :imports]` (or `trust: true`, the trust dialog alone), it
    first draws each startup dialog's screen in turn, its first option selected, as 2.1.322
    does: `trust-dialog`'s, then `imports-dialog`'s. Down and Up move the selection, Enter
    answers: "Yes, I trust this folder" goes on (and writes `<dir>/trusted`), "No, exit" exits;
    either imports option goes on, and writes it to `<dir>/imports` (`yes` or `no`); `:menu`
    among them draws the `menu` screen as one more startup dialog (F-203), its answer written
    as a running menu's, and the start goes on;
  - written with `transcript: true`, the start's prompt also goes into its transcript
    (`$CLAUDE_CONFIG_DIR/projects/<cwd>/<session>.jsonl`) as 2.1.322 writes a start's first
    turn, past its startup dialogs and not before: the session's title, agent name and modes,
    a file-history snapshot, then the user line whose `content` is the prompt, with
    `promptSource` `typed` (from the first end-to-end run's transcript, F-153);
  - with `--name`, the rule above the box carries the name, as 2.1.322 draws a session started
    with `--name` (`──── name ─`, F-153's capture).

  - its arguments, one to a line, go to `<dir>/argv/<pid>` (`argvs/1`), so a test reads the
    launch line a start gave it, as `HeadlessStandIn.argv/2` does for a headless delegate.

  Started by `Sessions` (`CLAUDE_CONFIG_DIR` set), it writes its session file as
  `CodingAgentFramework.ClaudeStandIn` does, once its startup dialogs are answered (2.1.322
  writes none while one is shown, F-140), and records its pid in `<dir>/pids/`. It exits after
  `idle` seconds with no key.
  """

  import CodingAgentFramework.TestHost, only: [program!: 1, stand_in_idle: 0]

  # The options of the menu fixture (`menu.ansi`), in order.
  @menu ["Yes", "Not now", "Don't show again"]

  @doc "The options of the menu `--screen menu` draws, in order."
  def menu, do: @menu

  @doc "What a person or the framework answered the menu with in `dir`: a label, `esc`, or nil."
  def menu_answer(dir) do
    case File.read(Path.join(dir, "menu")) do
      {:ok, n} when n in ["1", "2", "3"] -> Enum.at(@menu, String.to_integer(n) - 1)
      {:ok, other} -> other
      {:error, :enoent} -> nil
    end
  end

  @doc "The fixtures directory of `release`, in `caf_screen`'s tests."
  def fixtures(release),
    do: Path.expand("../../../caf_screen/test/fixtures/#{release}", __DIR__)

  @doc """
  Writes the stand-in for `release` into `dir` and answers its path. The screens are written
  beside it, from the release's fixtures.
  """
  def write!(dir, release \\ "2.1.322", idle \\ stand_in_idle(), opts \\ []) do
    screens = Path.join(dir, "screens-#{release}")
    File.mkdir_p!(screens)
    File.mkdir_p!(Path.join(dir, "pids"))
    File.mkdir_p!(Path.join(dir, "prompts"))
    File.mkdir_p!(Path.join(dir, "argv"))
    {top, bottom} = split_at_box(File.read!(Path.join(fixtures(release), "text-typed.txt")))
    # The rule above the box is drawn by the script, with the session's name when it has one.
    {top, [rule]} = Enum.split(top, -1)
    File.write!(Path.join(screens, "top"), Enum.map_join(top, &(&1 <> "\n")))
    File.write!(Path.join(screens, "rule"), rule <> "\n")
    File.write!(Path.join(screens, "bottom"), bottom)
    running = File.read!(Path.join(fixtures(release), "turn-running.txt"))
    File.write!(Path.join(screens, "running"), String.trim_trailing(running, "\n"))
    wait = File.read!(Path.join(fixtures(release), "usage-limit-wait.txt"))
    File.write!(Path.join(screens, "limit_wait"), String.trim_trailing(wait, "\n"))

    menu!(screens, release)
    dialog!(screens, release, "trust", " ", "No, exit", "Yes, I trust this folder")

    dialog!(
      screens,
      release,
      "imports",
      "  ",
      "No, disable external imports",
      "Yes, allow external imports"
    )

    dialogs = Keyword.get(opts, :dialogs, if(opts[:trust], do: [:trust], else: []))
    transcript = if opts[:transcript], do: "1", else: ""
    first = if opts[:menu], do: "menu", else: "idle"
    suffix = Enum.map_join(dialogs, &"-#{&1}") <> if(opts[:transcript], do: "-tx", else: "")
    suffix = suffix <> if(opts[:menu], do: "-menu", else: "")
    path = Path.join(dir, "claude-screen#{suffix}-#{release}")
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    File.write!(
      tmp,
      script(dir, screens, release, idle, Enum.join(dialogs, " "), transcript, first)
    )

    File.chmod!(tmp, 0o755)
    # Renamed into place, as `ClaudeStandIn.write!/3` does: a start may be running the path.
    File.rename!(tmp, path)
    path
  end

  @doc "The start prompts (the argument after `--`) the stand-ins started in `dir` ran."
  def prompts(dir) do
    case File.ls(Path.join(dir, "prompts")) do
      {:ok, files} -> Enum.map(files, &File.read!(Path.join([dir, "prompts", &1])))
      {:error, :enoent} -> []
    end
  end

  @doc """
  The arguments each stand-in started in `dir` was given, one list per start, in no order a
  test may rely on when it started more than one.
  """
  def argvs(dir) do
    case File.ls(Path.join(dir, "argv")) do
      {:ok, files} ->
        for f <- files,
            do: Path.join([dir, "argv", f]) |> File.read!() |> String.split("\n", trim: true)

      {:error, :enoent} ->
        []
    end
  end

  @doc "The lines the stand-in started in `dir` took at an Enter, oldest first."
  def submitted(dir) do
    case File.read(Path.join(dir, "submitted")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  # A two-option dialog's screens, each option selected: `<kind>-no` and `<kind>-yes`.
  defp dialog!(screens, release, kind, pad, no, yes) do
    file = Path.join(fixtures(release), "#{kind}-dialog.txt")
    shown = String.trim_trailing(File.read!(file), "\n")
    File.write!(Path.join(screens, "#{kind}-no"), shown)

    selected =
      shown
      |> String.replace(pad <> "❯ " <> no, pad <> "  " <> no)
      |> String.replace(pad <> "  " <> yes, pad <> "❯ " <> yes)

    File.write!(Path.join(screens, "#{kind}-yes"), selected)
  end

  # The menu no rule names (F-198) with the marker on each option: `menu-1` to `menu-3`.
  defp menu!(screens, release) do
    shown = String.trim_trailing(File.read!(Path.join(fixtures(release), "menu.ansi")), "\n")
    options = Enum.with_index(@menu, 1)

    plain =
      Enum.reduce(options, shown, fn {o, n}, s ->
        String.replace(s, "❯ #{n}. #{o}", "  #{n}. #{o}")
      end)

    for {o, n} <- options,
        do:
          File.write!(
            Path.join(screens, "menu-#{n}"),
            String.replace(plain, "  #{n}. #{o}", "❯ #{n}. #{o}")
          )
  end

  # The lines above the box's line, and those below it, the last with no newline: a newline
  # after the last row would scroll the screen by one.
  defp split_at_box(text) do
    lines = text |> String.trim_trailing("\n") |> String.split("\n")
    at = Enum.find_index(lines, &String.starts_with?(&1, "❯ "))
    {before, [_box | rest]} = Enum.split(lines, at)
    {before, Enum.join(rest, "\n")}
  end

  # The fixture's width, which a named rule fills as the plain one does.
  defp width(screens),
    do: screens |> Path.join("rule") |> File.read!() |> String.trim() |> String.length()

  defp script(dir, screens, release, idle, dialogs, transcript, first) do
    ~s"""
    #!#{program!(:bash)}
    name='' resume='' screen=#{first} sel=1 prompt='' dialogs='#{dialogs}' choice=no transcript='#{transcript}'
    given=$(printf '%s\\n' "$@")
    while [ $# -gt 0 ]; do
      case $1 in
        --version) printf '%s (Claude Code)\\n' '#{release}'; exit 0 ;;
        --name) name=$2; shift 2 ;;
        --resume) resume=$2; shift 2 ;;
        --screen) screen=$2; shift 2 ;;
        --) prompt=$2; break ;;
        *) shift ;;
      esac
    done
    # The startup dialogs left to answer; the first is shown.
    set -- $dialogs
    [ $# -gt 0 ] && screen=$1
    : 2>/dev/null > "#{dir}/pids/$$" || exit 0
    printf '%s\\n' "$given" 2>/dev/null > "#{dir}/argv/$$"
    file="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/sessions/$$.json}"
    announce() {
      [ -n "$file" ] || return 0
      start=$(LC_ALL=C TZ=UTC #{program!(:ps)} -o lstart= -p $$)
      start=${start#"${start%%[![:space:]]*}"}
      start=${start%"${start##*[![:space:]]}"}
      printf '{"pid": %d, "sessionId": "%s", "name": "%s", "cwd": "%s", "procStart": "%s", "status": "%s"}' \\
        $$ "${resume:-stand-in-$$}" "$name" "$PWD" "$start" "$1" > "$file.tmp"
      #{program!(:mv)} -f "$file.tmp" "$file"
    }
    # The rule above the box: the fixture's, or with --name the name in it, as 2.1.322 draws it.
    rule() {
      if [ -z "$name" ]; then #{program!(:cat)} "#{screens}/rule"; return; fi
      r='' i=0
      while [ $i -lt $((#{width(screens)} - ${#name} - 3)) ]; do r="$r─"; i=$((i + 1)); done
      printf '%s %s ─\\n' "$r" "$name"
    }
    # A string as JSON's string body: backslash, quote, newline and tab escaped.
    json() {
      local s=$1
      s=${s//\\\\/\\\\\\\\}; s=${s//\\"/\\\\\\"}; s=${s//$'\\n'/\\\\n}; s=${s//$'\\t'/\\\\t}
      printf '%s' "$s"
    }
    # The first turn's lines in the transcript, as 2.1.322 writes a start's prompt.
    tx() {
      [ -n "$transcript" ] && [ -n "$CLAUDE_CONFIG_DIR" ] || return 0
      sid=${resume:-stand-in-$$} at='2026-11-18T09:42:50.291Z'
      d="$CLAUDE_CONFIG_DIR/projects/${PWD//[^a-zA-Z0-9]/-}"
      #{program!(:mkdir)} -p "$d"
      {
        printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\\n' "$name" "$sid"
        printf '{"type":"agent-name","agentName":"%s","sessionId":"%s"}\\n' "$name" "$sid"
        printf '{"type":"mode","mode":"normal","sessionId":"%s"}\\n' "$sid"
        printf '{"type":"permission-mode","permissionMode":"auto","sessionId":"%s"}\\n' "$sid"
        printf '{"type":"file-history-snapshot","messageId":"m-%s","snapshot":{"messageId":"m-%s","trackedFileBackups":{},"timestamp":"%s"},"isSnapshotUpdate":false}\\n' $$ $$ "$at"
        printf '{"parentUuid":null,"isSidechain":false,"promptId":"p-%s","type":"user","message":{"role":"user","content":"%s"},"uuid":"m-%s","timestamp":"%s","permissionMode":"auto","origin":{"kind":"human"},"promptSource":"typed","turnOrigin":"human","turnPosition":{"promptIndex":1,"turnIndex":1},"userType":"external","entrypoint":"cli","cwd":"%s","sessionId":"%s","version":"#{release}","gitBranch":"main"}\\n' \\
          $$ "$(json "$prompt")" $$ "$at" "$(json "$PWD")" "$sid"
      } >> "$d/$sid.jsonl"
    }
    draw() {
      printf '\\033[H\\033[2J'
      if [ $screen = running ] || [ $screen = limit_wait ]; then
        #{program!(:cat)} "#{screens}/$screen"
      elif [ $screen = trust ] || [ $screen = imports ]; then
        #{program!(:cat)} "#{screens}/$screen-$choice"
      elif [ $screen = menu ]; then
        #{program!(:cat)} "#{screens}/menu-$sel"
      else
        #{program!(:cat)} "#{screens}/top"
        rule
        printf '❯ %s\\n' "$box"
        #{program!(:cat)} "#{screens}/bottom"
      fi
    }
    trap '[ -n "$file" ] && #{program!(:rm)} -f "$file"; #{program!(:stty)} echo icanon 2>/dev/null' EXIT
    trap 'exit 143' TERM
    # Keys are read one at a time with no echo, so text typed without an Enter is drawn by the
    # stand-in, in its box, as Claude Code draws it, and the terminal shows nothing else.
    #{program!(:stty)} -echo -icanon min 1
    # Past the startup dialogs: the session file, then the start's prompt as the first turn.
    first() {
      announce idle
      [ -n "$prompt" ] || return 0
      printf '%s' "$prompt" > "#{dir}/prompts/$$"
      tx
      announce busy
      announce idle
    }
    box=''
    [ $screen = idle ] && first
    [ $screen = running ] && announce idle
    [ $screen = limit_wait ] && announce busy
    # A menu among the startup dialogs is shown before the session file; a running one after it.
    [ $screen = menu ] && [ $# -eq 0 ] && announce idle
    draw
    while IFS= read -r -N1 -t #{idle} key; do
      if [ $screen = limit_wait ]; then
        continue
      elif [ $screen = menu ]; then
        # The marker moves; Enter answers its option, a lone Escape esc: the idle screen after,
        # or for a startup menu the next dialog, then the session as past the others.
        answer=''
        case $key in
          $'\\e') seq=''; IFS= read -r -N2 -t 0.2 seq
                 case $seq in
                   '[B') [ $sel -lt 3 ] && sel=$((sel + 1)) ;;
                   '[A') [ $sel -gt 1 ] && sel=$((sel - 1)) ;;
                   '') answer=esc ;;
                 esac ;;
          $'\\n'|$'\\r') answer=$sel ;;
        esac
        if [ -n "$answer" ]; then
          printf '%s' $answer > "#{dir}/menu"
          if [ $# -gt 0 ]; then
            shift; sel=1
            if [ $# -gt 0 ]; then screen=$1; else screen=idle; first; fi
          else
            screen=idle
          fi
        fi
      elif [ $screen = trust ] || [ $screen = imports ]; then
        case $key in
          $'\\e') IFS= read -r -N2 -t 1 seq
                 case $seq in '[B') choice=yes ;; '[A') choice=no ;; esac ;;
          $'\\n'|$'\\r')
            if [ $screen = trust ]; then
              [ $choice = yes ] || exit 1
              : > "#{dir}/trusted"
            else
              printf '%s' $choice > "#{dir}/imports"
            fi
            shift; choice=no
            if [ $# -gt 0 ]; then screen=$1; else screen=idle; first; fi ;;
        esac
      elif [ $screen = running ] && [ "$key" = $'\\e' ]; then
        # Escape interrupts the turn: the idle screen, as 2.1.322 shows after it.
        screen=idle
        : > "#{dir}/interrupted"
        announce idle
      elif [ "$key" = $'\\n' ] || [ "$key" = $'\\r' ]; then
        [ $screen = running ] && continue
        printf '%s\\n' "$box" >> "#{dir}/submitted"
        box=''
        announce busy
        announce idle
      else
        box="$box$key"
      fi
      # Drawn once no more keys wait, so a burst of keys is one draw, as Claude Code draws it.
      read -t 0 || draw
    done
    """
  end
end
