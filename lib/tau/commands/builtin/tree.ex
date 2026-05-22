defmodule Tau.Commands.Builtin.Tree do
  @moduledoc """
  Built-in `/tree` command.

  Renders the current session's parent/fork chain as a bounded ASCII tree.
  Reads `data.metadata[:forked_from]` (a `%{session: id, event: id}` map
  set by `Tau.Session.fork/2`).  Walks up to `@max_depth` ancestors via
  `Tau.Persistence`, collecting each ancestor's session id from its JSONL
  header.  Returns `{:notice, [lines]}` — never mutates session state and
  never drives a provider turn (D-042).

  If no fork ancestry exists, returns a single-line notice stating the
  session is a root.

  ## Depth cap

  Walking arbitrary chains in the session FSM could block the FSM for an
  unbounded time.  This implementation caps the walk at `@max_depth = 10`
  ancestors and emits a truncation notice if the cap is hit.
  """

  @behaviour Tau.Commands.Builtin

  @max_depth 10

  @impl Tau.Commands.Builtin
  def name, do: "/tree"

  @impl Tau.Commands.Builtin
  def description, do: "Show the session fork/clone lineage tree"

  @impl Tau.Commands.Builtin
  def run(_args, data) do
    session_id = data.id
    forked_from = Map.get(data.metadata || %{}, :forked_from)

    case build_chain(session_id, forked_from, 0) do
      {ancestors, truncated?} ->
        lines = render(ancestors, session_id, truncated?)
        {:notice, lines}
    end
  end

  # Returns `{[{depth, session_id}], truncated?}` — the chain from deepest
  # ancestor to current, each tagged with depth (0 = current).
  defp build_chain(current_id, nil, _depth) do
    # No parent — current is a root.
    {[{0, current_id, nil}], false}
  end

  defp build_chain(current_id, forked_from, depth) when depth >= @max_depth do
    parent_id = forked_from[:session] || forked_from["session"]
    {[{depth + 1, parent_id, :truncated}, {depth, current_id, forked_from}], true}
  end

  defp build_chain(current_id, forked_from, depth) do
    parent_id = forked_from[:session] || forked_from["session"]

    case read_header(parent_id) do
      nil ->
        # Parent session not found; stop here.
        {[{depth + 1, parent_id, :missing}, {depth, current_id, forked_from}], false}

      parent_header ->
        grandparent_forked =
          case parent_header["metadata"] do
            %{"forked_from" => gp} -> atomise_forked_from(gp)
            _ -> nil
          end

        {upper_chain, truncated?} = build_chain(parent_id, grandparent_forked, depth + 1)
        {upper_chain ++ [{depth, current_id, forked_from}], truncated?}
    end
  end

  defp read_header(session_id) do
    persistence = Tau.Persistence.impl()

    case persistence.stream(session_id) |> Enum.take(1) do
      [%{"kind" => "session_header", "data" => header}] -> header
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # The persisted header stores :forked_from as string-keyed (JSON round-trip).
  defp atomise_forked_from(%{"session" => s, "event" => e}), do: %{session: s, event: e}
  defp atomise_forked_from(%{session: _} = m), do: m
  defp atomise_forked_from(_), do: nil

  defp render(chain, _current_id, truncated?) do
    sorted = Enum.sort_by(chain, fn {depth, _, _} -> -depth end)

    header = ["Session fork tree:"]

    node_lines =
      sorted
      |> Enum.with_index()
      |> Enum.flat_map(fn {{depth, sid, info}, idx} ->
        is_last = idx == length(sorted) - 1
        prefix = if is_last, do: "└── ", else: "├── "
        indent = String.duplicate("    ", length(sorted) - 1 - depth)

        label =
          cond do
            info == nil -> "#{sid} (root)"
            info == :truncated -> "#{sid} (chain truncated at depth #{@max_depth})"
            info == :missing -> "#{sid} (not found in persistence)"
            is_last -> "#{sid} (current)"
            true -> "#{sid}"
          end

        ["#{indent}#{prefix}#{label}"]
      end)

    footer =
      if truncated?,
        do: ["(chain deeper than #{@max_depth} — only last #{@max_depth} ancestors shown)"],
        else: []

    header ++ node_lines ++ footer
  end
end
