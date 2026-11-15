defmodule CodingAgentFramework.SamplerSetup do
  @moduledoc """
  The setup `TmuxSamplerTest` and `TmuxSamplerSourceTest` share: a `TmuxSampler` of a real tmux
  server and a `Holder` of real dtach sockets, in the test's own directory.

  It compiles only for tests. It lives in `caf_sampler`, not `caf_test`, because it uses
  `TmuxSampler`, and `caf_test` may not use an app above it.

      setup {CodingAgentFramework.SamplerSetup, :sampler}
  """

  import CodingAgentFramework.TestHost
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias CodingAgentFramework.{Holder, Tmux, TmuxSampler}
  alias CodingAgentFramework.Tmux.CLI

  @doc "An ExUnit setup. The sampler's cues come to the test as `{:cue, cue}`."
  def sampler(_context) do
    dir = test_dir()
    socket = Path.join(dir, "tmux.sock")
    {:ok, server} = CLI.new(programs(), {:socket, socket})
    on_exit(fn -> Tmux.kill_server(server) end)
    File.mkdir_p!(Path.join(dir, "d"))
    {:ok, holder} = Holder.new(programs(), Path.join(dir, "d"))
    me = self()

    {:ok, sampler} =
      TmuxSampler.start_link(
        server: server,
        holder: holder,
        db: Path.join(dir, "s.db"),
        notify: &send(me, {:cue, &1})
      )

    {:ok, dir: dir, server: server, holder: holder, sampler: sampler}
  end
end
