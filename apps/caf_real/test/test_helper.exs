# Every program a test runs comes from devenv; a drift fails here, before any test, by name.
CodingAgentFramework.TestHost.check_environment!()
File.mkdir_p!(CodingAgentFramework.TestHost.vm_dir())
ExUnit.after_suite(fn _ -> CodingAgentFramework.TestHost.end_vm() end)

# The real Claude Code runs only under `mix test.real` (`--only real`); every other run of the
# suite, the gates' among them, leaves these tests out.
ExUnit.start(exclude: [:real], assert_receive_timeout: 5_000)
