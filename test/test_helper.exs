# Every program a test runs comes from devenv; a drift fails here, before any test, by name.
CodingAgentFramework.TestHost.check_environment!()

# Each test VM works under its own temporary directory, named with the VM's pid, and removes it
# when the suite ends. Every tmux server and dtach socket a test makes lives there.
File.mkdir_p!(CodingAgentFramework.TestHost.vm_dir())
ExUnit.after_suite(fn _ -> File.rm_rf(CodingAgentFramework.TestHost.vm_dir()) end)
ExUnit.start()
