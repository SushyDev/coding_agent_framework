defmodule CodingAgentFramework.ScreenStandIn do
  @moduledoc """
  A stand-in for Claude Code's screen, so no test starts the real one. It is a bash script that
  draws a release's captured fixtures (`apps/caf_screen/test/fixtures/<release>/`), as `Screen`
  reads them, and reads its input one key at a time with no echo:

  - idle, it draws `text-typed`'s screen with the box holding what was typed since the last
    Enter (an empty box is `❯` and a no-break space);
  - at Enter it appends the box's text, as one line, to `<dir>/submitted` (`submitted/2`), and
    runs a turn that ends at once: its session file says `busy`, then `idle`;
  - started with `--screen running`, it draws `turn-running`'s screen and never leaves it;
  - `--version` prints the release as Claude Code does (`2.1.322 (Claude Code)`) and exits;
  - the argument after `--` is the start's prompt, run as its first turn: written to
    `<dir>/prompts/<pid>` (`prompts/1`), its session file `busy`, then `idle`;
  - written with `dialogs: [:trust, :imports]` (or `trust: true`, the trust dialog alone), it
    first draws each startup dialog's screen in turn, its first option selected, as 2.1.322
    does: `trust-dialog`'s, then `imports-dialog`'s. Down and Up move the selection, Enter
    answers: "Yes, I trust this folder" goes on (and writes `<dir>/trusted`), "No, exit" exits;
    either imports option goes on, and writes it to `<dir>/imports` (`yes` or `no`).

  Started by `Sessions` (`CLAUDE_CONFIG_DIR` set), it writes its session file as
  `CodingAgentFramework.ClaudeStandIn` does, once its startup dialogs are answered (2.1.322
  writes none while one is shown, F-140), and records its pid in `<dir>/pids/`. It exits after
  `idle` seconds with no key.
  """

  import CodingAgentFramework.TestHost, only: [program!: 1, stand_in_idle: 0]

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
    {top, bottom} = split_at_box(File.read!(Path.join(fixtures(release), "text-typed.txt")))
    File.write!(Path.join(screens, "top"), top)
    File.write!(Path.join(screens, "bottom"), bottom)
    running = File.read!(Path.join(fixtures(release), "turn-running.txt"))
    File.write!(Path.join(screens, "running"), String.trim_trailing(running, "\n"))

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
    suffix = Enum.map_join(dialogs, &"-#{&1}")
    path = Path.join(dir, "claude-screen#{suffix}-#{release}")
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, script(dir, screens, release, idle, Enum.join(dialogs, " ")))
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

  # The lines above the box's line, and those below it, the last with no newline: a newline
  # after the last row would scroll the screen by one.
  defp split_at_box(text) do
    lines = text |> String.trim_trailing("\n") |> String.split("\n")
    at = Enum.find_index(lines, &String.starts_with?(&1, "❯ "))
    {before, [_box | rest]} = Enum.split(lines, at)
    {Enum.map_join(before, &(&1 <> "\n")), Enum.join(rest, "\n")}
  end

  defp script(dir, screens, release, idle, dialogs) do
    ~s"""
    #!#{program!(:bash)}
    name='' resume='' screen=idle prompt='' dialogs='#{dialogs}' choice=no
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
    draw() {
      printf '\\033[H\\033[2J'
      if [ $screen = running ]; then
        #{program!(:cat)} "#{screens}/running"
      elif [ $screen = trust ] || [ $screen = imports ]; then
        #{program!(:cat)} "#{screens}/$screen-$choice"
      else
        #{program!(:cat)} "#{screens}/top"
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
      announce busy
      announce idle
    }
    box=''
    [ $screen = idle ] && first
    [ $screen = running ] && announce idle
    draw
    while IFS= read -r -N1 -t #{idle} key; do
      if [ $screen = trust ] || [ $screen = imports ]; then
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
