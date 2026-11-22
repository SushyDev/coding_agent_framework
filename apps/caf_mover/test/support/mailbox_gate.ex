defmodule CodingAgentFramework.MailboxGate do
  @moduledoc """
  A stand-in for `Mailbox` in front of the real one, as the `Mover`'s `mailbox:`: each call goes
  on to the real `Mailbox`, except those `answer` answers itself. `answer` is a function of the
  request (`{:notify, to, text, key, kind, from}`, `{:launch, to, deadline, via}`, …) that
  answers `:pass` or `{:answer, reply}`. It lets a test make one answer of `Mailbox` unknown
  while the rest of it runs for real.

      gate = start_supervised!({MailboxGate, mailbox: mailbox, answer: fn
        {:notify, _, _, _, _, _} -> {:answer, {:unknown, :cannot_store}}
        _ -> :pass
      end})
      MailboxGate.answered(gate)
      #=> [{:notify, "d1", "This session was moved …", "move:d1:…", :notice, "framework"}]
  """

  use GenServer

  @doc "Starts the gate. Options: `mailbox:` (the real one) and `answer:`."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The requests the gate answered itself, oldest first."
  def answered(gate), do: GenServer.call(gate, {__MODULE__, :answered})

  @impl true
  def init(opts),
    do: {:ok, %{mailbox: Keyword.fetch!(opts, :mailbox), answer: opts[:answer], answered: []}}

  @impl true
  def handle_call({__MODULE__, :answered}, _from, s), do: {:reply, Enum.reverse(s.answered), s}

  def handle_call(request, _from, s) do
    case s.answer.(request) do
      {:answer, reply} -> {:reply, reply, %{s | answered: [request | s.answered]}}
      :pass -> {:reply, GenServer.call(s.mailbox, request, 15_000), s}
    end
  end
end
