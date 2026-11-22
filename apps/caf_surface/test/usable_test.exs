defmodule CodingAgentFramework.UsableTest do
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.Usable

  alias CodingAgentFramework.Usable

  # F-207: the app's check of an account, as its callback answers it.
  defmodule App do
    @behaviour CodingAgentFramework.Usable

    @impl true
    def usable?("flagged", opts, _part), do: {false, opts[:why]}
    def usable?("raises", _opts, _part), do: raise("no board")
    def usable?("exits", _opts, _part), do: exit(:gone)
    def usable?("odd", _opts, _part), do: :maybe
    def usable?("refused", _opts, _part), do: {:refused, :x}

    def usable?("live", _opts, part),
      do: if(part.(:logins) == :live, do: true, else: {false, :dead})

    def usable?(_account, _opts, _part), do: true
  end

  @entry {App, why: "same organization as side"}

  # A tree with no part started: every lookup answers nil.
  defp no_part(_key), do: nil

  test "an account the module allows is ok, one it refuses reads with the module's reason" do
    assert Usable.check(@entry, "work", &no_part/1) == :ok

    assert Usable.check(@entry, "flagged", &no_part/1) ==
             {:refused, {:app, "same organization as side"}}
  end

  test "the config holds no usable: every account is the framework's check alone" do
    assert Usable.check(nil, "flagged", &no_part/1) == :ok
  end

  test "the callback is given the live lookup of the parts, called when it runs" do
    assert Usable.check({App, []}, "live", fn :logins -> :live end) == :ok
    assert Usable.check({App, []}, "live", &no_part/1) == {:refused, {:app, :dead}}
  end

  test "a callback that raises, exits or answers oddly is unknown, never usable, never a raise" do
    assert Usable.check(@entry, "raises", &no_part/1) == {:unknown, {:raised, App, "no board"}}
    assert Usable.check(@entry, "exits", &no_part/1) == {:unknown, {:exit, App, :gone}}
    assert Usable.check(@entry, "odd", &no_part/1) == {:unknown, {:bad_answer, App, :maybe}}
    # The framework's own refusal shape is not the app's to answer.
    assert Usable.check(@entry, "refused", &no_part/1) ==
             {:unknown, {:bad_answer, App, {:refused, :x}}}
  end

  test "a module implements usable?/3 or it is not one" do
    assert Usable.implemented?(App)
    refute Usable.implemented?(Enum)
    refute Usable.implemented?(NoSuchModule)
  end
end
