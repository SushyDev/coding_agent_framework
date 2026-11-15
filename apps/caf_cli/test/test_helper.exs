# Every program a test runs comes from devenv; a drift fails here, before any test, by name.
CodingAgentFramework.TestHost.check_environment!()

# Each test VM works under its own temporary directory, named with the VM's pid, and removes it
# when the suite ends. Every tmux server and dtach socket a test makes lives there.
File.mkdir_p!(CodingAgentFramework.TestHost.vm_dir())
ExUnit.after_suite(fn _ -> File.rm_rf(CodingAgentFramework.TestHost.vm_dir()) end)
# A message a test waits for is announced, but under a heavy load it can take longer than
# ExUnit's 100 ms default to arrive. A wait still ends on the message, not on the timeout.
ExUnit.start(assert_receive_timeout: 5_000)
