defmodule Tau.Tool.Result do
  @moduledoc """
  Outcome of `Tau.Tool.execute/2`.

    * `:content` — what flows back to the model. Either a string or a list
      of content blocks (`%{type: :text|:image, ...}`).
    * `:details` — arbitrary structured metadata (truncation info, diffs,
      exit codes). Stays out of the model context, useful for the TUI and
      session JSONL.
    * `:terminate?` — hint that the agent should stop after this batch
      regardless of further model output (e.g. user-explicit `done`).
    * `:is_error` — set by tools (or hooks) when the result represents a
      failure that should be fed back to the model as `is_error: true`.
  """

  defstruct content: "", details: %{}, terminate?: false, is_error: false

  @type t :: %__MODULE__{
          content: String.t() | [map()],
          details: map(),
          terminate?: boolean(),
          is_error: boolean()
        }

  @spec text(String.t(), keyword()) :: t()
  def text(s, opts \\ []) do
    %__MODULE__{
      content: s,
      details: Keyword.get(opts, :details, %{}),
      terminate?: Keyword.get(opts, :terminate?, false),
      is_error: Keyword.get(opts, :is_error, false)
    }
  end

  @spec error(String.t(), keyword()) :: t()
  def error(msg, opts \\ []), do: text(msg, [{:is_error, true} | opts])
end
