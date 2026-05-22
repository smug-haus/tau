defmodule Tau.TUI.History do
  @cap 100

  @moduledoc """
  Pure value module for per-session prompt history.

  Maintains an ordered list of submitted prompts (most-recent last),
  a cursor for history recall navigation, and a draft buffer for
  preserving the in-progress entry while navigating.

  History is capped at #{@cap} entries; consecutive duplicate
  submissions are suppressed (D-143).
  """

  @type t :: %__MODULE__{
          entries: [String.t()],
          cursor: non_neg_integer() | nil,
          draft: String.t()
        }

  defstruct entries: [],
            cursor: nil,
            draft: ""

  @doc "New empty history."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Push a submitted entry. Deduplicate consecutive identical entries.
  Reset cursor to nil (at present, not in history). Cap at #{@cap} entries.
  """
  @spec push(t(), String.t()) :: t()
  def push(hist, ""), do: hist

  def push(%__MODULE__{entries: [last | _] = entries} = hist, text) when last == text do
    # Consecutive duplicate: suppress
    %{hist | entries: entries, cursor: nil, draft: ""}
  end

  def push(%__MODULE__{entries: entries} = hist, text) do
    new_entries =
      [text | entries]
      |> Enum.take(@cap)

    %{hist | entries: new_entries, cursor: nil, draft: ""}
  end

  @doc """
  Navigate to the previous (older) history entry.
  Saves the current in-progress draft on first navigation.
  Returns `{hist, text}` where text is the recalled entry, or
  `{hist, nil}` if already at the oldest.
  """
  @spec prev(t(), String.t()) :: {t(), String.t() | nil}
  def prev(%__MODULE__{entries: []} = hist, _current), do: {hist, nil}

  def prev(%__MODULE__{entries: entries, cursor: nil} = hist, current) do
    # Save draft and go to most recent
    new_cursor = 0

    %{hist | cursor: new_cursor, draft: current}
    |> recall(new_cursor, entries)
  end

  def prev(%__MODULE__{entries: entries, cursor: cursor} = hist, _current) do
    if cursor < length(entries) - 1 do
      new_cursor = cursor + 1

      %{hist | cursor: new_cursor}
      |> recall(new_cursor, entries)
    else
      {hist, nil}
    end
  end

  @doc """
  Navigate to the next (newer) history entry or restore draft.
  Returns `{hist, text}` where text is the newer entry or the saved draft,
  or `{hist, nil}` if already at the present (cursor == nil).
  """
  @spec next(t()) :: {t(), String.t() | nil}
  def next(%__MODULE__{cursor: nil} = hist), do: {hist, nil}

  def next(%__MODULE__{cursor: 0, draft: draft} = hist) do
    # Return to present
    {%{hist | cursor: nil, draft: ""}, draft}
  end

  def next(%__MODULE__{entries: entries, cursor: cursor} = hist) do
    new_cursor = cursor - 1

    %{hist | cursor: new_cursor}
    |> recall(new_cursor, entries)
  end

  @doc """
  Search for the most recent entry containing `query` (case-insensitive).
  Returns `{:match, entry}` or `:no_match`.
  Does not mutate cursor state — search mode is a separate layer in App.
  """
  @spec search(t(), String.t()) :: {:match, String.t()} | :no_match
  def search(_hist, ""), do: :no_match

  def search(%__MODULE__{entries: entries}, query) do
    lower = String.downcase(query)

    case Enum.find(entries, fn e -> String.contains?(String.downcase(e), lower) end) do
      nil -> :no_match
      entry -> {:match, entry}
    end
  end

  @doc "Return the entry at the given 0-based index (most-recent = 0)."
  @spec at(t(), non_neg_integer()) :: String.t() | nil
  def at(%__MODULE__{entries: entries}, idx), do: Enum.at(entries, idx)

  @doc "Number of entries."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{entries: entries}), do: length(entries)

  # Return the history entry at `idx` and the updated hist
  defp recall(hist, idx, entries) do
    {hist, Enum.at(entries, idx)}
  end
end
