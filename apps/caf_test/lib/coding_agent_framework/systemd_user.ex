defmodule CodingAgentFramework.SystemdUser do
  @moduledoc """
  Test aids for the host's own user systemd (F-274): its `systemd-run` and `systemctl`, found on
  the host's `PATH` since devenv brings neither, and whether it starts a scope here.

  A test VM's environment may lack `XDG_RUNTIME_DIR`, which `systemd-run --user` finds the user
  bus by, so each run names it: the VM's own when it has one, else `/run/user/<uid>`.

      {:ok, systemd} = SystemdUser.find()
      SystemdUser.run(systemd, systemd.ctl, ["--user", "stop", "caf-test-app-1"])
  """

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Programs, Shell}

  @enforce_keys [:run, :ctl, :runtime]
  defstruct [:run, :ctl, :runtime]

  @doc """
  This host's `systemd-run`, the `systemctl` beside it, and the runtime directory. Answers
  `{:ok, systemd}` or the refusal of the search.
  """
  def find do
    with :linux <- Programs.local_os(),
         {:ok, programs} <- Programs.find(host(), [:systemd_run]),
         {:ok, run} <- Programs.fetch(programs, :systemd_run),
         {:ok, runtime} <- runtime() do
      {:ok,
       %__MODULE__{run: run, ctl: Path.join(Path.dirname(run), "systemctl"), runtime: runtime}}
    else
      os when is_atom(os) -> {:refused, {:os, os}}
      other -> other
    end
  end

  @doc "Runs `program` with `args` and the user bus's runtime directory, as `Shell.run/4` answers."
  def run(%__MODULE__{runtime: runtime}, program, args),
    do:
      Shell.run(host(), program!(:env), ["XDG_RUNTIME_DIR=" <> runtime, program | args],
        timeout: 10_000
      )

  @doc """
  Whether this host's user systemd starts a scope: `systemd-run --user --scope` runs `true` and
  exits 0. `test_helper.exs` excludes the `:systemd_user` tag when it does not.
  """
  def available? do
    with {:ok, systemd} <- find(),
         {:ok, %{status: 0}} <-
           run(systemd, systemd.run, ["--user", "--scope", "--collect", "--quiet", program!(true)]) do
      true
    else
      _ -> false
    end
  end

  defp runtime do
    case System.get_env("XDG_RUNTIME_DIR") do
      "/" <> _ = dir ->
        {:ok, dir}

      _ ->
        case Shell.run(host(), program!(:id), ["-u"], timeout: 5_000) do
          {:ok, %{status: 0, output: uid}} -> {:ok, "/run/user/" <> String.trim(uid)}
          other -> {:refused, {:uid, other}}
        end
    end
  end
end
