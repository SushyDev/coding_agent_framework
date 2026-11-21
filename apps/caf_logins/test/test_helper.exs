# As every app's: programs from devenv, a directory per test VM, its stand-ins ended at the end.
CodingAgentFramework.TestHost.check_environment!()
File.mkdir_p!(CodingAgentFramework.TestHost.vm_dir())
ExUnit.after_suite(fn _ -> CodingAgentFramework.TestHost.end_vm() end)
ExUnit.start(assert_receive_timeout: 5_000)
