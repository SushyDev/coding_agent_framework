defmodule CodingAgentFramework.Accounts.Account do
  @moduledoc """
  One account and the paths of its framework files, as `CodingAgentFramework.Accounts` gives
  it. Only `Accounts.prepare/3` and `Accounts.ready/2` make one, after the files exist, so
  holding one means its config directory was there.

      iex> account = CodingAgentFramework.Accounts.Account.at("work", "/srv/caf/accounts/work/claude")
      iex> account.mcp_config
      "/srv/caf/accounts/work/claude/framework/mcp.json"
  """

  @enforce_keys [:name, :config_dir, :settings, :mcp_config]
  defstruct [:name, :config_dir, :settings, :mcp_config]

  @type t :: %__MODULE__{
          name: String.t(),
          config_dir: String.t(),
          settings: %{parent: String.t(), delegate: String.t()},
          mcp_config: String.t()
        }

  @doc "The account `name` whose config directory is `dir`. Pure."
  @spec at(String.t(), String.t()) :: t
  def at(name, dir) do
    own = Path.join(dir, "framework")

    %__MODULE__{
      name: name,
      config_dir: dir,
      settings: %{
        parent: Path.join(own, "parent.settings.json"),
        delegate: Path.join(own, "delegate.settings.json")
      },
      mcp_config: Path.join(own, "mcp.json")
    }
  end

  @doc "Every framework file of the account."
  @spec files(t) :: [String.t()]
  def files(%__MODULE__{} = a), do: [a.settings.parent, a.settings.delegate, a.mcp_config]
end
