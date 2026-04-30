defmodule Tau.Compactor do
  @moduledoc """
  Behaviour for context-window compaction strategies.

  When the session FSM detects that the in-memory message list has grown
  past a configured threshold (token-estimate or message count), it asks
  the configured `Tau.Compactor` whether to compact and, if so, what to
  swap into context in place of the older turns.

  Default: `Tau.Compactor.SummarizeTail`.
  """

  @callback should_compact?(messages :: [Tau.Message.t()], usage :: map()) :: boolean()

  @doc """
  Compact `messages`. On success, returns the new message list AND the
  raw summary text the strategy used to construct any synthetic
  summary message — `nil` if the strategy didn't summarise (e.g.,
  empty input, or a future strategy that compacts by some other
  rule).

  The session uses the returned `summary_text` directly (rather than
  greppping the new message list for it) when persisting the
  `compaction` event, so a hot-replay across `Tau.fork/2` /
  `Tau.resume/1` reconstructs the same summary message.
  """
  @callback compact(messages :: [Tau.Message.t()], ctx :: map()) ::
              {:ok, summary_messages :: [Tau.Message.t()], summary_text :: String.t() | nil}
              | {:error, term()}

  @doc "The configured compactor module."
  @spec impl() :: module()
  def impl, do: Application.get_env(:tau, :compactor, Tau.Compactor.SummarizeTail)
end
