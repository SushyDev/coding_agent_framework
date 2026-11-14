defmodule CodingAgentFramework.Tracker.Source do
  @moduledoc """
  A reader's table, as the `Tracker` reads it. Each reader (`Registry` now; `TmuxSampler`,
  `Holder`'s sockets, `Intake` and `Transcripts` later) gives one module with these callbacks,
  and the `Tracker` takes it as `{module, opts}`. The fold's contract does not change with them.

  A source opens its own connection to the reader's table, names the topic its reader cues on,
  and answers a read of rows by id (or `:all`) from the table, never from the cue.
  """

  @type state :: term

  @doc "Opens the source's own connection to its reader's table."
  @callback open(keyword) :: {:ok, state} | {:refused, term}

  @doc "From its options: the topic its reader cues on, the `{host, account}` of its rows, their kind."
  @callback describe(keyword) :: %{topic: String.t(), scope: {String.t(), String.t()}, kind: atom}

  @doc """
  Reads the rows with these ids, or every row with `:all`, and when the reader last read.
  An id that is absent from the answer has no row. `[]` asks only when the reader last read.
  """
  @callback read(state, :all | [term]) ::
              :unread | {:ok, %{read_at: integer, rows: [map]}} | {:unknown, term}
end
