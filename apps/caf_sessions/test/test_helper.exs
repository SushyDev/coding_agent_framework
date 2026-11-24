# Every program a test runs comes from devenv; a drift fails here, before any test, by name.
CodingAgentFramework.TestHost.check_environment!()

# Each test VM works under its own temporary directory, named with the VM's pid. Every tmux
# server and dtach socket a test makes lives there. When the suite ends, the VM ends every
# process a stand-in recorded there and removes the directory.
File.mkdir_p!(CodingAgentFramework.TestHost.vm_dir())
ExUnit.after_suite(fn _ -> CodingAgentFramework.TestHost.end_vm() end)
# The host's load, read once: the bounds of work that load lengthens are scaled by it (F-238).
%{load: load, cores: cores, scale: scale} = CodingAgentFramework.TestHost.read_load!()
IO.puts("test VM: load #{load} on #{cores} cores, load-sized bounds x#{scale}")
# A message a test waits for is announced, but under a heavy load it can take longer than
# ExUnit's 100 ms default to arrive. A wait still ends on the message, not on the timeout.
ExUnit.start(assert_receive_timeout: 5_000)
