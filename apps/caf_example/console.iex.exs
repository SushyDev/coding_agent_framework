# The shell `bin/caf-example` opens: the operator's console imported, and the app started from
# the config file it names, as `caf`. A config that is refused ends the shell with status 2.
import CodingAgentFramework.Example.Console

caf =
  case CodingAgentFramework.Example.Console.start(System.fetch_env!("CAF_EXAMPLE_CONFIG")) do
    {:ok, caf} -> caf
    _refused -> System.halt(2)
  end
