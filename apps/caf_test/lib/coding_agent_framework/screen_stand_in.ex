defmodule CodingAgentFramework.ScreenStandIn do
  @moduledoc """
  A stand-in for Claude Code's screen, so no test starts the real one. It is a bash script that
  draws a release's captured fixtures (`apps/caf_screen/test/fixtures/<release>/`), as `Screen`
  reads them, and reads its input one key at a time with no echo:

  - idle, it draws `text-typed`'s screen with the box holding what was typed since the last
    Enter (an empty box is `❯` and a no-break space);
  - it asks for bracketed paste (`ESC [?2004h`) at its start and again at each draw a resize
    makes, as Claude Code 2.1.322 appears to (F-287: multi-line pastes into real sessions a
    pane attached to under dtach long after their start arrived whole). Written with
    `paste_mode: :once`, it asks only at its start, so a pane that attaches under dtach later
    never sees it. It reads a paste by its markers (`ESC [200~` to `ESC [201~`) either way,
    as the framework brackets its paste itself. A paste goes into the box whole, its newlines kept (F-279), and is drawn as
    2.1.322 draws a paste (modeled, not captured): as its text when it is one line that fits,
    else folded, `[Pasted text #<n> +<newlines> lines]`;
  - at Enter it appends the box's text, as one line with each newline written `\n`, to
    `<dir>/submitted` (`submitted/2`), and runs a turn that ends at once: its session file
    says `busy`, then `idle`;
  - started with `--screen running`, it draws `turn-running`'s screen, its session file `busy`,
    until Escape, which ends the turn: it writes `<dir>/interrupted`, says `idle` and draws the
    idle screen;
  - started with `--screen limit_wait`, it draws `usage-limit-wait`'s screen, Claude Code's own
    wait at a usage limit, and takes no key; its session file says `busy`, since what 2.1.322's
    says during the wait was never measured (F-191), so only the screen tells the wait;
  - started with `--screen menu`, or written with `menu: true`, it draws the `menu` fixture's screen (F-198), a menu no rule
    names above the box, its marker on its first option, its session file `waiting` with
    `waitingFor` `dialog open`, as 2.1.322's says while its exit dialog is open (F-232). Down
    and Up move the marker; Enter answers its option and a lone Escape `esc`, each written to
    `<dir>/menu` (`menu_answer/1`), and the idle screen is drawn after, the file `idle`;
  - started with `--screen ask`, it draws the `ask-question` fixture's screen (F-230), Claude
    Code's own question in the box's place, its marker on its first of four options, its
    session file `waiting` as the menu's, and takes keys as the menu does: Enter writes its
    option's number as drawn to `<dir>/menu`;
  - `auth status` answers a logged-in login, as `HeadlessStandIn` does, so a whole tree's login
    check passes before a start;
  - `--version` prints the release as Claude Code does (`2.1.322 (Claude Code)`) and exits;
  - the argument after `--` is the start's prompt, run as its first turn: written to
    `<dir>/prompts/<pid>` (`prompts/1`), its session file `busy`, then `idle`;
  - written with `dialogs: [:trust, :imports]` (or `trust: true`, the trust dialog alone), it
    first draws each startup dialog's screen in turn, its first option selected, as 2.1.322
    does: `trust-dialog`'s, then `imports-dialog`'s. Down and Up move the selection, Enter
    answers: "Yes, I trust this folder" goes on (and writes `<dir>/trusted`), "No, exit" exits;
    either imports option goes on, and writes it to `<dir>/imports` (`yes` or `no`); `:menu`
    among them draws the `menu` screen as one more startup dialog (F-203), its answer written
    as a running menu's, and the start goes on; `:menu2` draws it with another title
    (`menu_titles/0`), a second onboarding step (F-206), and each menu's answer is appended
    to `<dir>/menus` (`menu_answers/1`); each key the trust or imports dialog takes is
    appended to `<dir>/dialog_keys` (`dialog_keys/1`): `down`, `up`, `enter`. Written with
    `marks: true` too, it draws no trust dialog in a folder whose real path
    `$CLAUDE_CONFIG_DIR/.claude.json` marks under `projects`, as 2.1.322 does (F-255): the
    entry `{"hasTrustDialogAccepted":true}` as `Accounts.trust/3` writes a new one, compact;
  - written with `redraw: ms` too, it draws the trust dialog again once, `ms` after its first
    draw, as 2.1.322 does about 150 ms after it (F-246): until then a key moves the marker on
    the screen only and an Enter is dropped, and the second draw puts the marker and the
    choice back on "No, exit". With `redraw: {:every, ms}` it draws it again every `ms`, the
    marker on the other option each time, so it never reads the same for longer;
  - written with `transcript: true`, the start's prompt also goes into its transcript
    (`$CLAUDE_CONFIG_DIR/projects/<cwd>/<session>.jsonl`) as 2.1.322 writes a start's first
    turn, past its startup dialogs and not before: the session's title, agent name and modes,
    a file-history snapshot, then the user line whose `content` is the prompt, with
    `promptSource` `typed` (from the first end-to-end run's transcript, F-153);
  - at an Enter with `/reload-plugins` in the box, it draws the command's echo and, under it,
    a result line above the box, as `Screen.result/3` reads 2.1.322's (modeled, not captured:
    F-233's new-1), one pair per reload; written with `reloaded: false`, the echo alone, a
    reload that never draws its result;
  - with `--name`, the rule above the box carries the name, as 2.1.322 draws a session started
    with `--name` (`──── name ─`, F-153's capture).

  - its arguments, one to a line, go to `<dir>/argv/<pid>` (`argvs/1`), so a test reads the
    launch line a start gave it, as `HeadlessStandIn.argv/2` does for a headless delegate.

  Started by `Sessions` (`CLAUDE_CONFIG_DIR` set), it writes its session file,
  `<CLAUDE_CONFIG_DIR>/sessions/<pid>.json`, once its startup dialogs are answered (2.1.322
  writes none while one is shown, F-140), making `sessions/` as Claude Code does, and removes
  it when it exits. Its `procStart` is macOS's form, `ps -o lstart=` in UTC; written with
  `proc_start: ticks` it is that string, Linux's form, a start in clock ticks (F-246); written
  with `proc_start: {:stat, dir}` it is the start in ticks that `<dir>/<pid>/stat` holds as it
  writes the file: `"/proc"` on Linux, or a test's own directory where it wrote that file. The file has 2.1.322's shape in the fields the framework reads (`pid`,
  `sessionId`, `cwd`, `startedAt`, `procStart`, `kind`, `name`, `status`, `updatedAt`, and
  `waitingFor` while a dialog is drawn) plus `version`. Written with `session_file: false`, it
  writes none. It records its pid in `<dir>/pids/`, and exits after `idle` seconds with no key.
  """

  import CodingAgentFramework.TestHost, only: [program!: 1, stand_in_idle: 0]

  # The options of the menu fixture (`menu.ansi`), in order.
  @menu ["Yes", "Not now", "Don't show again"]

  # The fixture's title, and the one `:menu2` draws in its place: a second onboarding step.
  @title "Teach auto mode about your environment?"
  @title2 "Turn on notifications for this device?"

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

  @doc "The titles of the menus `:menu` and `:menu2` draw among the startup dialogs, in order."
  def menu_titles, do: [@title, @title2]

  @doc "Every answer to a menu in `dir`, oldest first: labels, or `esc`."
  def menu_answers(dir) do
    case File.read(Path.join(dir, "menus")) do
      {:ok, text} ->
        for n <- String.split(text, "\n", trim: true),
            do: if(n in ["1", "2", "3"], do: Enum.at(@menu, String.to_integer(n) - 1), else: n)

      {:error, :enoent} ->
        []
    end
  end

  @doc "The keys the trust and imports dialogs took in `dir`, oldest first: `down`, `up`, `enter`."
  def dialog_keys(dir) do
    case File.read(Path.join(dir, "dialog_keys")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
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

    menu!(screens, release, "menu", @title)
    menu!(screens, release, "menu2", @title2)
    ask!(screens, release)
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
    reloaded = if Keyword.get(opts, :reloaded, true), do: "1", else: ""
    first = if opts[:menu], do: "menu", else: "idle"
    suffix = Enum.map_join(dialogs, &"-#{&1}") <> if(opts[:transcript], do: "-tx", else: "")
    suffix = suffix <> if(opts[:menu], do: "-menu", else: "")
    suffix = suffix <> if(reloaded == "", do: "-silent", else: "")
    session_file = if Keyword.get(opts, :session_file, true), do: "1", else: ""
    suffix = suffix <> if(session_file == "", do: "-nofile", else: "")

    {redraw, every} =
      case Keyword.get(opts, :redraw) do
        nil -> {"", ""}
        {:every, ms} when is_integer(ms) and ms > 0 -> {"", "#{ms}"}
        ms when is_integer(ms) and ms > 0 -> {"#{ms}", ""}
      end

    suffix = suffix <> if(redraw != "", do: "-redraw#{redraw}", else: "")
    suffix = suffix <> if(every != "", do: "-every#{every}", else: "")
    dialogs = Enum.join(dialogs, " ")

    {proc_start, stat_dir} =
      case Keyword.get(opts, :proc_start, "") do
        {:stat, dir} when is_binary(dir) -> {"", dir}
        ticks when is_binary(ticks) -> {ticks, ""}
      end

    suffix = suffix <> if(proc_start <> stat_dir != "", do: "-ticks", else: "")
    marks = if opts[:marks], do: "1", else: ""
    suffix = suffix <> if(marks != "", do: "-marks", else: "")
    once = if opts[:paste_mode] == :once, do: "1", else: ""
    suffix = suffix <> if(once != "", do: "-once", else: "")
    path = Path.join(dir, "claude-screen#{suffix}-#{release}")
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    flags =
      {release, idle, dialogs, transcript, first, session_file, reloaded,
       {redraw, every, proc_start, stat_dir, marks, once}}

    File.write!(tmp, script(dir, screens, flags))

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

  # The menu no rule names (F-198) with the marker on each option: `<name>-1` to `<name>-3`,
  # its title `title`.
  defp menu!(screens, release, name, title) do
    shown = String.trim_trailing(File.read!(Path.join(fixtures(release), "menu.ansi")), "\n")
    shown = String.replace(shown, @title, title)
    options = Enum.with_index(@menu, 1)

    plain =
      Enum.reduce(options, shown, fn {o, n}, s ->
        String.replace(s, "❯ #{n}. #{o}", "  #{n}. #{o}")
      end)

    for {o, n} <- options,
        do:
          File.write!(
            Path.join(screens, "#{name}-#{n}"),
            String.replace(plain, "  #{n}. #{o}", "❯ #{n}. #{o}")
          )
  end

  # Claude Code's own question (F-230) with the marker on each of its four options: `ask-1` to
  # `ask-4`. Its rules, 200 columns in the fixture, are redrawn at the stand-in's width, so the
  # pane wraps none of them.
  defp ask!(screens, release) do
    w = width(screens)
    rule = String.duplicate("─", w)

    shown =
      Path.join(fixtures(release), "ask-question.txt")
      |> File.read!()
      |> String.trim_trailing("\n")
      |> String.replace(~r/^─+$/mu, rule)
      |> String.replace(
        ~r/^─+ capture-main ─$/mu,
        String.duplicate("─", w - 15) <> " capture-main ─"
      )

    plain = String.replace(shown, "❯ 1. ", "  1. ")

    for n <- 1..4,
        do:
          File.write!(
            Path.join(screens, "ask-#{n}"),
            String.replace(plain, "  #{n}. ", "❯ #{n}. ")
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

  defp script(dir, screens, flags) do
    {release, idle, dialogs, transcript, first, session_file, reloaded,
     {redraw, every, proc_start, stat_dir, marks, once}} = flags

    ~s"""
    #!#{program!(:bash)}
    # The login check a whole tree runs before a start, answered as `HeadlessStandIn` does.
    if [ "$1 $2" = "auth status" ]; then
      printf '{"loggedIn": true, "authMethod": "stand_in", "loginExpiresAt": null}\\n'; exit 0
    fi
    name='' resume='' screen=#{first} sel=1 prompt='' dialogs='#{dialogs}' choice=no transcript='#{transcript}'
    reloaded='#{reloaded}' shown=''
    # `choice` is the option the dialog holds, `drawn` the one its marker is drawn on. Until a
    # pending second draw (`redraw`, once; `every`, always), only `drawn` moves.
    drawn=no redraw='#{redraw}' every='#{every}' pending='' first_at=0
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
    # With `marks`, a folder `.claude.json` marks trusted by its real path shows no trust
    # dialog (F-255). Only then is the file read: a test VM may inherit a config dir that is
    # not its own.
    if [ -n "#{marks}" ] && [ -n "$CLAUDE_CONFIG_DIR" ]; then
      json=$(#{program!(:cat)} "$CLAUDE_CONFIG_DIR/.claude.json" 2>/dev/null)
      mark="\\"$(pwd -P)\\":{\\"hasTrustDialogAccepted\\":true"
      [[ $json == *"$mark"* ]] && dialogs=${dialogs#trust}
    fi
    # The startup dialogs left to answer; the first is shown.
    set -- $dialogs
    [ $# -gt 0 ] && screen=$1
    : 2>/dev/null > "#{dir}/pids/$$" || exit 0
    printf '%s\\n' "$given" 2>/dev/null > "#{dir}/argv/$$"
    file=''
    [ -n "#{session_file}" ] && file="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/sessions/$$.json}"
    # Epoch milliseconds, as the real file's `startedAt` and `updatedAt` are.
    ms() { local t=${EPOCHREALTIME/./}; printf '%s' "${t:0:13}"; }
    started=$(ms)
    # The session file in 2.1.322's shape, the fields the framework reads and `version`;
    # `waitingFor` only with status `waiting`, as the real one writes it while a dialog is open.
    # Its directory is made here, as Claude Code makes it: no one else does in a whole tree.
    announce() {
      [ -n "$file" ] || return 0
      start=$(LC_ALL=C TZ=UTC #{program!(:ps)} -o lstart= -p $$)
      start=${start#"${start%%[![:space:]]*}"}
      start=${start%"${start##*[![:space:]]}"}
      # Linux's form, a start in clock ticks, when the stand-in is written with one (F-246).
      [ -n "#{proc_start}" ] && start='#{proc_start}'
      # Or the ticks of its own stat file: field 22, the 20th past the name's last `)`.
      if [ -n "#{stat_dir}" ]; then
        stat=$(<"#{stat_dir}/$$/stat"); stat=(${stat##*)}); start=${stat[19]}
      fi
      waiting=''
      [ "$1" = waiting ] && waiting=', "waitingFor": "dialog open"'
      #{program!(:mkdir)} -p "${file%/*}"
      printf '{"pid": %d, "sessionId": "%s", "cwd": "%s", "startedAt": %s, "procStart": "%s", "version": "%s", "kind": "interactive", "name": "%s", "status": "%s", "updatedAt": %s%s}' \\
        $$ "${resume:-stand-in-$$}" "$(json "$PWD")" "$started" "$start" '#{release}' "$(json "$name")" "$1" "$(ms)" "$waiting" > "$file.tmp"
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
      drawing=1
      paint
      drawing=''
      if [ -n "$winched" ]; then resized; fi
    }
    paint() {
      printf '\\033[H\\033[2J'
      if [ $screen = running ] || [ $screen = limit_wait ]; then
        #{program!(:cat)} "#{screens}/$screen"
      elif [ $screen = trust ] || [ $screen = imports ]; then
        #{program!(:cat)} "#{screens}/$screen-$drawn"
      elif [ $screen = menu ] || [ $screen = menu2 ] || [ $screen = ask ]; then
        #{program!(:cat)} "#{screens}/$screen-$sel"
      else
        #{program!(:cat)} "#{screens}/top"
        printf '%s' "$shown"
        rule
        printf '❯ %s\\n' "$view"
        #{program!(:cat)} "#{screens}/bottom"
      fi
    }
    trap '[ -n "$file" ] && #{program!(:rm)} -f "$file"; #{program!(:stty)} echo icanon 2>/dev/null' EXIT
    trap 'exit 143' TERM
    # Keys are read one at a time with no echo, so text typed without an Enter is drawn by the
    # stand-in, in its box, as Claude Code draws it, and the terminal shows nothing else.
    #{program!(:stty)} -echo -icanon min 1
    # Bracketed paste on, as Claude Code asks for it. dtach keeps no output, so a pane that
    # attaches later sees it only when a resize asks again (`resized`); with `paste_mode: :once`
    # none does.
    printf '\\033[?2004h'
    # Claude Code draws again when its size changes, and only then (F-272). dtach keeps no
    # output, so a screen drawn before a viewer attached shows only once the viewer's grow
    # makes it draw again. Bash runs the trap while a read waits, and the read goes on.
    # A trap also runs between a draw's commands, so a resize then waits for the draw's end.
    resized() {
      winched=''
      local now; now=$(#{program!(:stty)} size 2>/dev/null)
      [ "$now" = "$size" ] && return 0
      size=$now
      [ -n "#{once}" ] || printf '\\033[?2004h'
      draw
    }
    winched='' drawing='' size=$(#{program!(:stty)} size 2>/dev/null)
    trap 'if [ -n "$drawing" ]; then winched=1; else resized; fi' WINCH
    # Past the startup dialogs: the session file, then the start's prompt as the first turn.
    # `busy` comes before the prompt's file, so a test that has seen the prompt knows the file's
    # next `idle` is the turn's end, not the one before it.
    first() {
      announce idle
      [ -n "$prompt" ] || return 0
      announce busy
      printf '%s' "$prompt" > "#{dir}/prompts/$$"
      tx
      announce idle
    }
    # `box` is the text the box holds, `view` how it is drawn, `pastes` the pastes in it.
    box='' view='' pastes=0
    [ $screen = idle ] && first
    [ $screen = running ] && announce busy
    [ $screen = limit_wait ] && announce busy
    # A menu among the startup dialogs is shown before the session file; a running one after it,
    # which says `waiting` while it is drawn, as Claude Code's own question does.
    [ $screen = menu ] && [ $# -eq 0 ] && announce waiting
    [ $screen = ask ] && announce waiting
    last=3; [ $screen = ask ] && last=4
    draw
    # The trust dialog's second draw is pending from its first (F-246).
    if [ $screen = trust ] && [ -n "$redraw$every" ]; then pending=1; first_at=$(ms); fi
    # The second draw: the marker and the choice back on the first option; with `every`, the
    # marker on the other option each time, and another draw pending.
    again() {
      choice=no
      if [ -n "$every" ]; then
        [ $drawn = no ] && drawn=yes || drawn=no
        first_at=$(ms)
      else
        drawn=no; pending=''
      fi
      draw
    }
    while :; do
      wait=#{idle}
      if [ -n "$pending" ]; then
        left=$((first_at + ${redraw:-$every} - $(ms)))
        if [ $left -le 0 ]; then again; continue; fi
        wait=$(printf '%d.%03d' $((left / 1000)) $((left % 1000)))
      fi
      IFS= read -r -N1 -t $wait key
      got=$?
      # A read that timed out on a pending draw draws it; any other end of input ends.
      if [ $got -ne 0 ]; then [ -n "$pending" ] && [ $got -gt 128 ] && continue; break; fi
      if [ $screen = limit_wait ]; then
        continue
      elif [ $screen = menu ] || [ $screen = menu2 ] || [ $screen = ask ]; then
        # The marker moves; Enter answers its option, a lone Escape esc: the idle screen after,
        # or for a startup menu the next dialog, then the session as past the others.
        answer=''
        case $key in
          $'\\e') seq=''; IFS= read -r -N2 -t 0.2 seq
                 case $seq in
                   '[B') [ $sel -lt $last ] && sel=$((sel + 1)) ;;
                   '[A') [ $sel -gt 1 ] && sel=$((sel - 1)) ;;
                   '') answer=esc ;;
                 esac ;;
          $'\\n'|$'\\r') answer=$sel ;;
        esac
        if [ -n "$answer" ]; then
          printf '%s' $answer > "#{dir}/menu"
          printf '%s\\n' $answer >> "#{dir}/menus"
          if [ $# -gt 0 ]; then
            shift; sel=1
            if [ $# -gt 0 ]; then screen=$1; else screen=idle; first; fi
          else
            screen=idle
            announce idle
          fi
        fi
      elif [ $screen = trust ] || [ $screen = imports ]; then
        case $key in
          $'\\e') IFS= read -r -N2 -t 1 seq
                 case $seq in
                   '[B') drawn=yes; printf 'down\\n' >> "#{dir}/dialog_keys" ;;
                   '[A') drawn=no; printf 'up\\n' >> "#{dir}/dialog_keys" ;;
                 esac
                 [ -n "$pending" ] || choice=$drawn ;;
          $'\\n'|$'\\r')
            printf 'enter\\n' >> "#{dir}/dialog_keys"
            # Before the dialog's second draw an Enter is dropped, as 2.1.322 drops it.
            [ -n "$pending" ] && continue
            if [ $screen = trust ]; then
              [ $choice = yes ] || exit 1
              : > "#{dir}/trusted"
            else
              printf '%s' $choice > "#{dir}/imports"
            fi
            shift; choice=no drawn=no
            if [ $# -gt 0 ]; then screen=$1; else screen=idle; first; fi ;;
        esac
      elif [ $screen = running ] && [ "$key" = $'\\e' ]; then
        # Escape interrupts the turn: the idle screen, as 2.1.322 shows after it.
        screen=idle
        : > "#{dir}/interrupted"
        announce idle
      elif [ "$key" = $'\\n' ] || [ "$key" = $'\\r' ]; then
        [ $screen = running ] && continue
        printf '%s\\n' "${box//$'\\n'/\\\\n}" >> "#{dir}/submitted"
        if [ "$box" = /reload-plugins ]; then
          shown="$shown❯ /reload-plugins"$'\\n'
          [ -n "$reloaded" ] && shown="$shown  ⎿  Reloaded: 1 plugin · 0 skills · 0 agents · 0 hooks"$'\\n'
        fi
        box='' view='' pastes=0
        announce busy
        announce idle
      elif [ "$key" = $'\\e' ]; then
        # A bracketed paste: its text, any newline in it, up to the closing marker, read so
        # whatever the pane saw. Its text holds no escape: `Tmux.paste_text/1` refuses one.
        seq=''; IFS= read -r -N5 -t 1 seq
        if [ "$seq" = '[200~' ]; then
          text=''; IFS= read -r -d $'\\e' text; IFS= read -r -N5 -t 1 seq
          box="$box$text"; pastes=$((pastes + 1))
          if [[ $text == *$'\\n'* ]] || [ ${#text} -gt $((#{width(screens)} - 4 - ${#view})) ]; then
            nl=${text//[!$'\\n']/}
            view="$view[Pasted text #$pastes +${#nl} lines]"
          else
            view="$view$text"
          fi
        else
          box="$box$key$seq" view="$view$key$seq"
        fi
      else
        box="$box$key" view="$view$key"
      fi
      # Drawn once no more keys wait, so a burst of keys is one draw, as Claude Code draws it.
      read -t 0 || draw
    done
    """
  end
end
