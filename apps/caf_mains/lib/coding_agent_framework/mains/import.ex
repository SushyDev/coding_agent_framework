defmodule CodingAgentFramework.Mains.Import do
  @moduledoc """
  An app's existing Claude Code conversations moved onto the framework once (F-156):
  `bin/caf-import`'s work, and the manifest `Mains` reads at its start.

      bin/caf-import <home> <account> <source config dir> [--map <old cwd>=<project>]...
        [--name <session id>=<name>]... [--meta <session id>=<json>]... [--replace <name>]...
        [--db <path>]

  **What it copies** (`run/1`), never moving, from the source config directory into the home's
  account directory `<home>/accounts/<account>/claude`, once:

  - each conversation of a mapped working directory, `projects/<encoded old cwd>/<id>.jsonl`,
    with the directory of that name beside it and `session-env/<id>` (what a move copies, as
    `Mover` does), into `projects/<encoded checkout>/`, the encoded path of the mapped
    project's checkout (`Transcripts.project_dir/2`), so `--resume <id>` in the checkout finds
    it;
  - that directory's memory, `projects/<encoded old cwd>/memory/`, into the home's one memory
    folder of the checkout (`Sessions.Memory.dir/2`, F-155), file by file;
  - the person's settings: `settings.json`, `CLAUDE.md`, `agents/`, `commands/` and `skills/`,
    each only when the account has none of its own. A setting of a copied `settings.json` that
    names an absolute path this host lacks (a hook's command, an additional directory) is kept
    as it is, never rewritten, and named in the report with its key (`missing_paths/2`, F-177).

  The login stays with the account's own (`bin/caf-login`): `.credentials.json` and
  `.claude.json` are never copied.

  **Where the checkout is**: the `checkouts` row of the mapped project (`Mains.Table`), which
  `Mains` writes from its first start on, in the app's tables: `--db`, by default the home's
  `caf.db`, the name the app's surface gives them (F-177). So the app starts once on the new
  host, which makes the checkouts, before an import. The file is read and never written:
  `Sessions` and `Mains` are its writers.

  **Refused** with nothing copied: while any agent row of the account may hold a process
  (`Sessions.Agents.free?/1`, `{:running, names}`), and while a Claude Code the person runs by
  hand on the account's or the source's config directory may (F-177): their session files,
  `sessions/<pid>.json`, are read as the `Registry` reads them (`Registry.running/3`), each pid
  checked by its start time, never by its name, `{:running, pids}`, or `{:may_run, pids}` for
  one `ps` lists whose start time is not known; since Claude Code rewrites what it keeps from
  memory; for a
  conversation whose files are already in the account and differ, or memory files that differ
  (`{:conflicts, paths}`); for a name given twice, or to a session not found under a mapped
  cwd. Each file is copied whole under a temporary name and renamed.

  **The manifest.** Each conversation copied is recorded in
  `<home>/imports/<account>/<session id>.json`, written last: its session id, account,
  project, old and new cwd, and the `--name` and `--meta` given for it. A second import of the
  same session copies nothing and says it was imported already. At each start `Mains` reads
  the manifests (`manifest/1`) and has `Sessions` write each named conversation as a main
  session's row, `stopped` with its session id (`Sessions.import_main/4`), so the app's
  start-or-resume resumes it (`Mains.resume_main/3`).

  **A replace** (F-271): `--replace <name>`, for a name this run gives with `--name`, lets the
  row take over that name's main session when the app started one before the import (a fresh
  conversation of the same name). The manifest records `replace_at`, the run's time, and a rerun
  for a conversation imported already stamps it again. `Sessions` then replaces a `main` row
  that holds no process and was started before `replace_at`, with the manifest's session id and
  account; a row that runs, or one started after it, stays refused `{:exists, status}`, so a
  later start under the name is never undone at the app's next start. The rows go through `Sessions`, their one
  writer, at the app's start rather than through a call into the running app's node: the app
  runs no distributed node and names no process, and an import on a new host is made before
  its sessions ever run.

      iex> CodingAgentFramework.Mains.Import.parse(["/caf", "work", "/old/.claude",
      ...>   "--map", "/src/app=app", "--name", "s1=app-epic", "--meta", ~s(s1={"epic":7})])
      {:ok, %{home: "/caf", account: "work", source: "/old/.claude", maps: [{"/src/app", "app"}],
        names: %{"s1" => "app-epic"}, metas: %{"s1" => %{"epic" => 7}}, replace: [],
        db: "/caf/caf.db"}}
      iex> {:ok, %{db: db}} = CodingAgentFramework.Mains.Import.parse(["/caf", "work", "/old",
      ...>   "--map", "/src/app=app", "--db", "/var/app/tables.db"])
      iex> db
      "/var/app/tables.db"
  """

  alias CodingAgentFramework.{Accounts, Host, Programs, Registry, Transcripts}
  alias CodingAgentFramework.Mains.Table
  alias CodingAgentFramework.Sessions.{Agents, Memory, Worktree}

  @settings ~w(settings.json CLAUDE.md agents commands skills)
  @session ~r/\A[A-Za-z0-9_-]{1,64}\z/

  @doc """
  The script's entry: parses `argv`, runs the import, prints what it did, and halts. The
  programs it reads session files with (sh, cat, env, ps and kill) are devenv's, from `env`'s
  `CAF_<NAME>` variables, the environment `bin/caf-import` runs in.
  """
  @spec main([String.t()], %{String.t() => String.t()}) :: no_return
  def main(argv, env \\ System.get_env()) do
    code =
      with {:ok, opts} <- parse(argv),
           {:ok, programs} <- programs(env),
           {:ok, lines} <- run(Map.put(opts, :programs, programs)) do
        Enum.each(lines, &IO.puts("caf-import: " <> &1))
        0
      else
        {:usage, why} ->
          IO.puts(:stderr, "caf-import: #{why}")
          2

        {:refused, why} ->
          IO.puts(:stderr, "caf-import: refused: #{inspect(why)}")
          3

        {:unknown, why} ->
          IO.puts(:stderr, "caf-import: failed part way, run it again: #{inspect(why)}")
          1
      end

    System.halt(code)
  end

  @doc """
  The script's arguments as `run/1` takes them, or `{:usage, why}`. `db` is `--db`'s path, by
  default `<home>/caf.db`; `replace` the `--replace` names, in order.
  """
  @spec parse([String.t()]) :: {:ok, map} | {:usage, String.t()}
  def parse([home, account, source | flags]) do
    acc = %{home: home, account: account, source: source, maps: [], names: %{}, metas: %{}}
    acc = Map.put(acc, :replace, [])

    with {:ok, acc} <- flags(flags, Map.put(acc, :db, nil)),
         do: {:ok, %{acc | db: acc.db || Path.join(home, "caf.db")}}
  end

  def parse(_), do: {:usage, "usage: bin/caf-import <home> <account> <source config dir> ..."}

  defp flags([], acc), do: {:ok, %{acc | maps: Enum.reverse(acc.maps)}}

  defp flags(["--map", pair | rest], acc) do
    # The project's name has no `=`; a path may.
    case String.split(pair, "=") do
      [_, _ | _] = parts ->
        {project, old} = List.pop_at(parts, -1)
        flags(rest, %{acc | maps: [{Enum.join(old, "="), project} | acc.maps]})

      _ ->
        {:usage, "--map takes <old cwd>=<project>: #{pair}"}
    end
  end

  defp flags(["--name", pair | rest], acc) do
    case String.split(pair, "=", parts: 2) do
      [sid, name] -> flags(rest, %{acc | names: Map.put(acc.names, sid, name)})
      _ -> {:usage, "--name takes <session id>=<name>: #{pair}"}
    end
  end

  defp flags(["--meta", pair | rest], acc) do
    with [sid, text] <- String.split(pair, "=", parts: 2),
         {:ok, %{} = meta} <- JSON.decode(text) do
      flags(rest, %{acc | metas: Map.put(acc.metas, sid, meta)})
    else
      _ -> {:usage, "--meta takes <session id>=<a JSON object>: #{pair}"}
    end
  end

  defp flags(["--db", path | rest], acc), do: flags(rest, %{acc | db: path})

  defp flags(["--replace", name | rest], acc),
    do: flags(rest, %{acc | replace: Enum.uniq(acc.replace ++ [name])})

  defp flags([flag | _], _acc), do: {:usage, "unknown or incomplete option #{flag}"}

  defp programs(env) do
    paths =
      for name <- [:sh, :cat, :env, :ps, :kill],
          path = env["CAF_" <> String.upcase(Atom.to_string(name))],
          is_binary(path),
          into: %{},
          do: {name, path}

    case paths do
      %{kill: kill} -> Programs.new(Host.local("local", kill), paths)
      _ -> {:refused, {:no_program, :kill}}
    end
  end

  @doc """
  Imports as the module doc says. `opts`: `home`, `account`, `source`, `maps` (`[{old cwd,
  project}]`), `names` and `metas` (by session id), `replace` (names), `programs` (this host's, naming sh, cat,
  env and ps), and optionally `db` (the app's tables, by default `<home>/caf.db`). Answers
  `{:ok, lines}`, what it did and what was imported already; `{:refused, reason}` with nothing
  copied; or `{:unknown, reason}` when a copy failed part way (a second run goes on from what
  is there).
  """
  @spec run(map) :: {:ok, [String.t()]} | {:refused, term} | {:unknown, term}
  def run(%{home: home, account: account, source: source} = o) do
    path = Map.get(o, :db) || Path.join(home, "caf.db")

    with {:ok, accounts} <- Accounts.new(home, [account]),
         {:ok, config} <- Accounts.config_dir(accounts, account),
         :ok <- source_ok(source, config),
         :ok <- args_ok(o),
         {:ok, programs} <- Map.fetch(o, :programs) |> or_refused({:missing, :programs}),
         {:ok, db} <- db(path),
         {:ok, host, paths} <- checkouts(db, o.maps),
         :ok <- idle(path, host, account),
         :ok <- by_hand(programs, [config, source]),
         {:ok, plan} <- plan(o, config, paths),
         :ok <- conflicts(plan) do
      act(plan)
    end
  end

  @doc """
  Every conversation imported into `home`, from the manifests: `%{session_id, account,
  project, name, meta, cwd}` each, `name` nil for one given none. A file that cannot be read
  is left out.
  """
  @spec manifest(Path.t()) :: [map]
  def manifest(home) do
    root = Path.join(home, "imports")

    for account <- ls(root),
        file <- ls(Path.join(root, account)),
        String.ends_with?(file, ".json"),
        {:ok, text} <- [File.read(Path.join([root, account, file]))],
        {:ok, %{"session_id" => sid} = m} <- [JSON.decode(text)] do
      %{
        session_id: sid,
        account: m["account"],
        project: m["project"],
        name: m["name"],
        meta: m["meta"],
        cwd: m["cwd"],
        replace_at: m["replace_at"]
      }
    end
  end

  # -- Checks, before anything is copied -----------------------------------------------------

  defp source_ok(source, config) do
    cond do
      Path.type(source) != :absolute -> {:refused, {:bad, :source}}
      not File.dir?(source) -> {:refused, {:no_source, source}}
      Path.expand(source) == Path.expand(config) -> {:refused, {:same_dir, source}}
      true -> :ok
    end
  end

  defp args_ok(o) do
    names = Map.values(o.names)

    cond do
      o.maps == [] ->
        {:refused, {:missing, :map}}

      bad = Enum.find(o.maps, fn {old, _} -> Path.type(old) != :absolute end) ->
        {:refused, {:bad_cwd, elem(bad, 0)}}

      bad = Enum.find(Map.keys(o.names), &(not (&1 =~ @session))) ->
        {:refused, {:bad_session_id, bad}}

      bad = Enum.find(names, &(not Worktree.name?(&1))) ->
        {:refused, {:bad_name, bad}}

      twice = names -- Enum.uniq(names) ->
        if twice == [], do: metas_ok(o), else: {:refused, {:name_twice, hd(twice)}}
    end
  end

  defp metas_ok(o) do
    case Enum.find(Map.keys(o.metas), &(not Map.has_key?(o.names, &1))) do
      nil -> replace_ok(o)
      sid -> {:refused, {:meta_without_name, sid}}
    end
  end

  # A name to replace is one this run gives a conversation (F-271).
  defp replace_ok(o) do
    names = Map.values(o.names)

    case Enum.find(Map.get(o, :replace, []), &(&1 not in names)) do
      nil -> :ok
      name -> {:refused, {:replace_without_name, name}}
    end
  end

  defp or_refused({:ok, _} = ok, _why), do: ok
  defp or_refused(:error, why), do: {:refused, why}

  # Mains writes the file from the app's first start; read here, never written.
  defp db(path) do
    if File.regular?(path),
      do: Table.open(path),
      else: {:refused, {:no_app_start, path}}
  end

  # Each mapped project's checkout, on the one host that runs the main sessions.
  defp checkouts(db, maps) do
    rows = for {_, project} <- Enum.uniq(maps), do: {project, Table.project_rows(db, project)}

    case Enum.find(rows, fn {_, found} -> found == [] end) do
      {project, _} ->
        {:refused, {:no_checkout, project}}

      nil ->
        hosts = rows |> Enum.flat_map(fn {_, found} -> Enum.map(found, & &1.host) end)

        case Enum.uniq(hosts) do
          [host] -> {:ok, host, Map.new(rows, fn {p, [row]} -> {p, row.path} end)}
          many -> {:refused, {:hosts, many}}
        end
    end
  end

  defp idle(path, host, account) do
    with {:ok, agents} <- Agents.open(path, host) do
      case for(r <- Agents.rows(agents), r.account == account, not Agents.free?(r), do: r.name) do
        [] -> :ok
        names -> {:refused, {:running, names}}
      end
    end
  end

  # A Claude Code run by hand on the account's or the source's directory is no agent row
  # (F-156's new-4): its session files say so, each pid checked by its start time. One whose
  # start time is not known may run, so it refuses too.
  defp by_hand(programs, dirs) do
    case Registry.running(programs, dirs) do
      {:ok, %{live: [], unknown: []}} -> :ok
      {:ok, %{live: [], unknown: pids}} -> {:refused, {:may_run, pids}}
      {:ok, %{live: pids}} -> {:refused, {:running, pids}}
      {:unknown, why} -> {:refused, {:sessions_unread, why}}
      refused -> refused
    end
  end

  # -- The plan: every copy, and what is there already ----------------------------------------

  defp plan(o, config, paths) do
    with {:ok, dirs} <- dirs(o, config, paths) do
      sessions = Enum.flat_map(dirs, &sessions(&1, o, config))
      found = MapSet.new(sessions, & &1.sid)

      case Enum.find(Map.keys(o.names), &(not MapSet.member?(found, &1))) do
        nil ->
          taken(o, %{sessions: sessions, memory: memory(o, dirs), settings: settings(o, config)})

        sid ->
          {:refused, {:unknown_session, sid}}
      end
    end
  end

  # A name an earlier import gave another session.
  defp taken(o, plan) do
    held = for e <- manifest(o.home), e.name, into: %{}, do: {e.name, e.session_id}

    case Enum.find(o.names, fn {sid, name} -> Map.get(held, name, sid) != sid end) do
      nil -> {:ok, plan}
      {_, name} -> {:refused, {:name_taken, name}}
    end
  end

  defp dirs(o, config, paths) do
    Enum.reduce_while(o.maps, {:ok, []}, fn {old, project}, {:ok, acc} ->
      cwd = paths[project]

      with {:ok, from} <- Transcripts.project_dir(o.source, old),
           {:ok, to} <- Transcripts.project_dir(config, cwd),
           {:ok, memory} <- Memory.dir(o.home, cwd) do
        dir = %{old: old, project: project, cwd: cwd, from: from, to: to, memory: memory}
        {:cont, {:ok, acc ++ [dir]}}
      else
        {:refused, why} -> {:halt, {:refused, {why, old}}}
      end
    end)
  end

  defp sessions(dir, o, config) do
    for file <- ls(dir.from), String.ends_with?(file, ".jsonl"), sid = Path.rootname(file) do
      done = Path.join([o.home, "imports", o.account, sid <> ".json"])
      env = Path.join("session-env", sid)

      %{
        sid: sid,
        dir: dir,
        done: done,
        already: File.exists?(done),
        file: {Path.join(dir.from, file), Path.join(dir.to, file)},
        side: {Path.join(dir.from, sid), Path.join(dir.to, sid)},
        env: {Path.join(o.source, env), Path.join(config, env)},
        entry: %{
          "session_id" => sid,
          "account" => o.account,
          "project" => dir.project,
          "old_cwd" => dir.old,
          "cwd" => dir.cwd,
          "name" => o.names[sid],
          "meta" => o.metas[sid]
        },
        replace: o.names[sid] != nil and o.names[sid] in Map.get(o, :replace, [])
      }
    end
  end

  # Each memory file under a mapped cwd's folder, to the home's folder of its checkout.
  defp memory(_o, dirs) do
    for dir <- dirs,
        root = Path.join(dir.from, "memory"),
        rel <- files(root, ""),
        do: {Path.join(root, rel), Path.join(dir.memory, rel)}
  end

  defp settings(o, config) do
    for name <- @settings, from = Path.join(o.source, name), exists?(from) do
      {name, from, Path.join(config, name)}
    end
  end

  defp conflicts(plan) do
    sessions =
      for s <- plan.sessions,
          not s.already,
          {from, to} = s.file,
          exists?(to),
          not same?(from, to),
          do: to

    memory =
      plan.memory
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
      |> Enum.filter(fn {to, sources} ->
        (exists?(to) and Enum.any?(sources, &(not same?(&1, to)))) or
          length(Enum.uniq_by(sources, &File.read/1)) > 1
      end)
      |> Enum.map(&elem(&1, 0))

    case Enum.sort(sessions ++ memory) do
      [] -> :ok
      paths -> {:refused, {:conflicts, paths}}
    end
  end

  # -- The copies ---------------------------------------------------------------------------

  @doc """
  Each setting of `settings` (a decoded `settings.json`) that names an absolute path for which
  `exists?` is false, as `{key, path}`: the key as its place in the JSON, the path as the
  setting writes it, a command's other words left out. A URL is no path.

      iex> settings = %{
      ...>   "$schema" => "https://json.schemastore.org/claude-code-settings.json",
      ...>   "hooks" => %{"Stop" => [%{"hooks" => [%{"command" => "/old/bin/stop.sh --quiet"}]}]},
      ...>   "permissions" => %{"additionalDirectories" => ["/srv/app", "/old/docs"]}}
      iex> CodingAgentFramework.Mains.Import.missing_paths(settings, &(&1 == "/srv/app"))
      [{"hooks.Stop[0].hooks[0].command", "/old/bin/stop.sh"},
       {"permissions.additionalDirectories[1]", "/old/docs"}]
  """
  @spec missing_paths(term, (String.t() -> boolean)) :: [{String.t(), String.t()}]
  def missing_paths(settings, exists?), do: settings |> leaves("") |> missing(exists?)

  # A path starts a word: after the start, a space, a quote, `=`, `:` or `(`, never `//`.
  @path ~r{(?<![^\s"'=:(])/(?!/)[^\s"'`;|&()<>,]*}

  defp missing(leaves, exists?) do
    for {key, text} <- leaves,
        [path] <- Regex.scan(@path, text),
        not exists?.(path),
        do: {key, path}
  end

  defp leaves(%{} = map, at) do
    map
    |> Enum.sort()
    |> Enum.flat_map(fn {k, v} -> leaves(v, if(at == "", do: k, else: "#{at}.#{k}")) end)
  end

  defp leaves(list, at) when is_list(list) do
    list |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> leaves(v, "#{at}[#{i}]") end)
  end

  defp leaves(text, at) when is_binary(text), do: [{at, text}]
  defp leaves(_other, _at), do: []

  defp act(plan) do
    with {:ok, settings} <- each(plan.settings, &setting/1),
         {:ok, memory} <- each(plan.memory, &memory_file/1),
         {:ok, sessions} <- each(plan.sessions, &session/1) do
      copied = Enum.count(memory, &(&1 == :copied))

      {:ok,
       List.flatten(settings) ++
         ["memory: #{copied} file(s) copied, #{length(memory) - copied} there already"] ++
         sessions}
    end
  end

  defp each(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, line} -> {:cont, {:ok, acc ++ [line]}}
        failed -> {:halt, failed}
      end
    end)
  end

  defp setting({name, from, to}) do
    if exists?(to) do
      {:ok, "settings: #{name} kept: the account has its own"}
    else
      with :ok <- copy_whole(from, to), do: {:ok, ["settings: #{name} copied" | named_paths(to)]}
    end
  end

  # The copied settings' paths this host lacks, kept as they are, for a person to see to
  # (F-156's new-5).
  defp named_paths(path) do
    with "settings.json" <- Path.basename(path),
         {:ok, text} <- File.read(path),
         {:ok, %{} = settings} <- JSON.decode(text) do
      for {key, missing} <- missing_paths(settings, &exists?/1),
          do: "settings: settings.json keeps #{key}, naming #{missing}, not on this host"
    else
      _ -> []
    end
  end

  defp memory_file({from, to}) do
    if exists?(to), do: {:ok, :there}, else: with(:ok <- copy_whole(from, to), do: {:ok, :copied})
  end

  # A replace asked of a conversation imported before stamps its manifest again (F-271), so
  # a person reruns the import with --replace once its name's row is in the way.
  defp session(%{already: true, replace: true} = s) do
    with {:ok, text} <- File.read(s.done) |> named(s.done),
         {:ok, %{} = entry} <- JSON.decode(text) |> named(s.done),
         entry = Map.merge(entry, %{"name" => s.entry["name"], "replace_at" => now()}),
         :ok <- write_whole(s.done, JSON.encode!(entry)) do
      {:ok, "#{s.sid}: imported already; replaces main session #{s.entry["name"]}'s row"}
    end
  end

  defp session(%{already: true} = s),
    do: {:ok, "#{s.sid}: imported already (#{label(s)})"}

  defp session(s) do
    {from, to} = s.file

    with :ok <- copy_whole(s.side),
         :ok <- copy_whole(s.env),
         :ok <- if(exists?(to), do: :ok, else: copy_whole(from, to)),
         :ok <- write_whole(s.done, JSON.encode!(done_entry(s))) do
      {:ok, "#{s.sid}: imported (#{label(s)})"}
    end
  end

  defp done_entry(s) do
    at = now()
    entry = Map.put(s.entry, "imported_at", at)
    if s.replace, do: Map.put(entry, "replace_at", at), else: entry
  end

  defp label(s) do
    named = if n = s.entry["name"], do: "main session #{n}, ", else: "no name, "
    named <> "project #{s.dir.project}, in #{s.dir.cwd}"
  end

  # A directory or file beside a conversation, when the source has one: whole, in place of a
  # copy a cut run left (its conversation is not there, so the manifest names it not).
  defp copy_whole({from, to}) do
    if exists?(from) do
      File.rm_rf(to)
      copy_whole(from, to)
    else
      :ok
    end
  end

  defp copy_whole(from, to) do
    tmp = to <> ".importing"
    File.rm_rf(tmp)

    with :ok <- File.mkdir_p(Path.dirname(to)) |> named(to),
         {:ok, _} <- File.cp_r(from, tmp) |> named(tmp),
         :ok <- File.rename(tmp, to) |> named(to),
         do: :ok
  end

  defp write_whole(path, text) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)) |> named(path),
         :ok <- File.write(tmp, text) |> named(tmp),
         do: File.rename(tmp, path) |> named(path)
  end

  defp named(:ok, _), do: :ok
  defp named({:ok, _} = ok, _), do: ok
  defp named({:error, why}, path), do: {:unknown, {:file, path, why}}
  defp named({:error, why, _}, path), do: {:unknown, {:file, path, why}}

  defp now, do: System.os_time(:millisecond)

  defp files(root, rel) do
    dir = Path.join(root, rel)

    cond do
      File.regular?(dir) ->
        [rel]

      File.dir?(dir) ->
        Enum.flat_map(ls(dir), &files(root, if(rel == "", do: &1, else: Path.join(rel, &1))))

      true ->
        []
    end
  end

  defp same?(a, b), do: File.read(a) == File.read(b)
  defp exists?(path), do: match?({:ok, _}, File.lstat(path))

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.sort(entries)
      _ -> []
    end
  end
end
