# The shell `bin/caf-example` opens: the operator's console imported, and the app started from
# the config file it names, as `caf`. A config that is refused ends the shell with status 2.
# IEx runs this file again in each new shell (after an interrupt, say): the app started once
# per VM is `caf` again, and nothing starts twice (`Console.shell/2`).
import CodingAgentFramework.Example.Console

caf =
  case CodingAgentFramework.Example.Console.shell(System.fetch_env!("CAF_EXAMPLE_CONFIG")) do
    {:ok, caf} -> caf
    _refused -> System.halt(2)
  end
