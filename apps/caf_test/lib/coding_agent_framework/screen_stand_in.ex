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
  - written with `trust: true`, it first draws `trust-dialog`'s screen, "No, exit" selected:
    Down and Up move the selection, Enter on "Yes, I trust this folder" goes on (and writes
    `<dir>/trusted`), Enter on "No, exit" exits.

  Started by `Sessions` (`CLAUDE_CONFIG_DIR` set), it writes its session file as
  `CodingAgentFramework.ClaudeStandIn` does, and records its pid in `<dir>/pids/`. It exits
  after `idle` seconds with no key.
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

    trust =
      String.trim_trailing(File.read!(Path.join(fixtures(release), "trust-dialog.txt")), "\n")

    File.write!(Path.join(screens, "trust-no"), trust)

    yes =
      trust
      |> String.replace(" ❯ No, exit", "   No, exit")
      |> String.replace("   Yes, I trust this folder", " ❯ Yes, I trust this folder")

    File.write!(Path.join(screens, "trust-yes"), yes)

    name = if opts[:trust], do: "claude-screen-trust-#{release}", else: "claude-screen-#{release}"
    path = Path.join(dir, name)
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, script(dir, screens, release, idle, if(opts[:trust], do: 1, else: 0)))
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

  # The lines above the box's line, and those below it, the last with no newline: a newline
  # after the last row would scroll the screen by one.
  defp split_at_box(text) do
    lines = text |> String.trim_trailing("\n") |> String.split("\n")
    at = Enum.find_index(lines, &String.starts_with?(&1, "❯ "))
    {before, [_box | rest]} = Enum.split(lines, at)
    {Enum.map_join(before, &(&1 <> "\n")), Enum.join(rest, "\n")}
  end

  defp script(dir, screens, release, idle, trust) do
    ~s"""
    #!#{program!(:bash)}
    name='' resume='' screen=idle prompt='' trust=#{trust} choice=no
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
    [ $trust = 1 ] && screen=trust
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
      elif [ $screen = trust ]; then
        #{program!(:cat)} "#{screens}/trust-$choice"
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
    # The start's prompt runs as the first turn, once the trust dialog is passed.
    first() {
      [ -n "$prompt" ] || return 0
      printf '%s' "$prompt" > "#{dir}/prompts/$$"
      announce busy
      announce idle
    }
    box=''
    announce idle
    [ $screen = trust ] || first
    draw
    while IFS= read -r -N1 -t #{idle} key; do
      if [ $screen = trust ]; then
        case $key in
          $'\\e') IFS= read -r -N2 -t 1 seq
                 case $seq in '[B') choice=yes ;; '[A') choice=no ;; esac ;;
          $'\\n'|$'\\r') [ $choice = yes ] || exit 1
                       screen=idle; : > "#{dir}/trusted"; first ;;
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
