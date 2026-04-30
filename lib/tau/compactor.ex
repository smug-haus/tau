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
  @callback compact(messages :: [Tau.Message.t()], ctx :: map()) ::
              {:ok, summary_messages :: [Tau.Message.t()]} | {:error, term()}

  @doc "The configured compactor module."
  @spec impl() :: module()
  def impl, do: Application.get_env(:tau, :compactor, Tau.Compactor.SummarizeTail)
end
