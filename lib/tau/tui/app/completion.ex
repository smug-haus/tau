if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.App.Completion do
    @moduledoc """
    Slash-command autocomplete menu helpers for `Tau.TUI.App`.
    Manages `model.menu` and `model.catalog` state. All functions
    are pure: they take and return the MVU model map.

    ## Contract

    The menu opens when the editor text is a `/`-prefixed whitespace-free
    token. It re-filters on every input change and closes on whitespace
    or when the input no longer starts with `/`. Acceptance fills the
    editor with the selected command name and a trailing space (D-106).
    SPEC-TUI-COMPLETION §4 B1/B2 (D-100..D-109).
    """

    alias Tau.TUI.Editor
    alias Tau.TUI.Fuzzy
    alias Tau.Commands.Builtin

    @doc """
    Return the builtins floor used when no catalog has been received yet (D-104).
    """
    @spec catalog_floor() :: [map()]
    def catalog_floor do
      Builtin.table()
      |> Enum.map(fn {name, mod} ->
        desc =
          if function_exported?(mod, :description, 0), do: mod.description(), else: ""

        %{name: name, description: desc, origin: :builtin}
      end)
      |> Enum.sort_by(& &1.name)
    end

    @doc """
    Return the effective catalog: the received catalog if present, else the builtins floor.
    """
    @spec effective_catalog(map()) :: [map()]
    def effective_catalog(%{catalog: nil}), do: catalog_floor()
    def effective_catalog(%{catalog: entries}), do: entries

    @doc """
    Recompute whether the menu should be open, closed, or re-filtered after any
    input change. Opens on a `/`-prefixed whitespace-free token; closes otherwise.
    """
    @spec update_menu(map()) :: map()
    def update_menu(model) do
      input = Editor.text(model.editor)
      trimmed = String.trim_leading(input)

      if String.starts_with?(trimmed, "/") and not String.contains?(trimmed, " ") do
        query = String.slice(trimmed, 1..-1//1)
        candidates = effective_catalog(model)
        ranked = Fuzzy.match(query, candidates)
        selected = clamp(Map.get(model.menu || %{}, :selected, 0), length(ranked) - 1)
        %{model | menu: %{query: query, entries: ranked, selected: selected}}
      else
        %{model | menu: nil}
      end
    end

    @doc """
    Close the menu if the editor input now contains whitespace (space was typed).
    """
    @spec close_menu_if_whitespace(map()) :: map()
    def close_menu_if_whitespace(model) do
      input = Editor.text(model.editor)

      if String.contains?(input, " ") do
        %{model | menu: nil}
      else
        model
      end
    end

    @doc """
    Move the menu selection by `delta` rows, clamped to `[0, count-1]`.
    No-op when the menu is closed.
    """
    @spec menu_navigate(map(), integer()) :: map()
    def menu_navigate(%{menu: nil} = model, _delta), do: model

    def menu_navigate(%{menu: menu} = model, delta) do
      count = length(menu.entries)
      new_selected = clamp(menu.selected + delta, count - 1)
      %{model | menu: %{menu | selected: new_selected}}
    end

    @doc """
    Accept the currently-selected menu entry: fill the editor with the entry
    name followed by a space and close the menu. Does NOT submit (D-106).

    When the menu is open with no entries (e.g. user typed a complete command
    not in the autocomplete set), closes the menu and signals the caller to
    submit by returning `{:submit, model}` — the caller must call `submit/1`.
    Returns `{:ok, model}` on a normal accept.
    """
    @spec menu_accept(map()) :: map()
    def menu_accept(%{menu: nil} = model), do: model

    # D-173: empty entries list → close menu; caller (Keymap) is responsible for submit.
    def menu_accept(%{menu: %{entries: [], selected: _}} = model) do
      %{model | menu: nil}
    end

    def menu_accept(%{menu: %{entries: entries, selected: selected}} = model) do
      idx = clamp(selected, length(entries) - 1)
      {_score, entry} = Enum.at(entries, idx)
      new_editor = Editor.new() |> Editor.insert(entry.name <> " ")
      %{model | editor: new_editor, menu: nil}
    end

    @doc """
    Clamp `n` to the range `[0, max]`. Returns `0` when `max < 0`.
    """
    @spec clamp(integer(), integer()) :: non_neg_integer()
    def clamp(_n, max) when max < 0, do: 0
    def clamp(n, _max) when n < 0, do: 0
    def clamp(n, max) when n > max, do: max
    def clamp(n, _max), do: n
  end
end
