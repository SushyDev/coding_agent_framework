defmodule CodingAgentFramework.Logins.Status do
  @moduledoc """
  What `claude auth status` printed, as a login's state. Pure and total.

  Claude Code 2.1.322 prints JSON by default (measured in F-181): `loggedIn` (a boolean),
  `authMethod` (`"none"`, `"oauth_token"`, …), `loginExpiresAt` (nil, or when the login ends,
  in ms), and the directories it read; it exits 0 when logged in and 1 when not. It reads the
  login the launch would, so it runs with the launch's environment (`CLAUDE_CONFIG_DIR`, and on
  macOS `USER` and `PATH` for the Keychain).

      iex> alias CodingAgentFramework.Logins.Status
      iex> Status.parse(0, ~s({"loggedIn": true, "authMethod": "oauth_token", "loginExpiresAt": null}), 1_000)
      {:ok, %{logged_in: true, method: "oauth_token", expires_at: nil}}
      iex> Status.parse(1, ~s({"loggedIn": false, "authMethod": "none"}), 1_000)
      {:refused, :logged_out}
      iex> Status.parse(0, ~s({"loggedIn": true, "authMethod": "claude.ai", "loginExpiresAt": 900}), 1_000)
      {:refused, :expired}
      iex> Status.parse(0, "Not logged in.", 1_000)
      {:malformed, :not_json}
  """

  @doc """
  The state in `output` of a run that exited with `status`, at `now` (ms): `{:ok, %{logged_in:
  true, method, expires_at}}`, `{:refused, :logged_out}`, `{:refused, :expired}` (a login whose
  `loginExpiresAt` passed), or `{:malformed, reason}`.
  """
  @spec parse(integer, binary, integer) :: {:ok, map} | {:refused, atom} | {:malformed, term}
  def parse(status, output, now) when is_integer(status) and is_binary(output) do
    case JSON.decode(output) do
      {:ok, %{"loggedIn" => true} = j} -> logged_in(j, now)
      {:ok, %{"loggedIn" => false}} -> {:refused, :logged_out}
      {:ok, _} -> {:malformed, :no_logged_in}
      {:error, _} -> {:malformed, :not_json}
    end
  end

  def parse(_status, _output, _now), do: {:malformed, :not_text}

  defp logged_in(j, now) do
    method = if is_binary(j["authMethod"]), do: j["authMethod"]

    case j["loginExpiresAt"] do
      at when is_integer(at) and at <= now -> {:refused, :expired}
      at when is_integer(at) -> {:ok, %{logged_in: true, method: method, expires_at: at}}
      _ -> {:ok, %{logged_in: true, method: method, expires_at: nil}}
    end
  end
end
