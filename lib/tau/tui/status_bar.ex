if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.StatusBar do
    @moduledoc """
    Pure render module for the TUI status bar (D-162 / SPEC-TUI-HEADLESS §5d).

    `render/1` takes the MVU model and returns a Ratatouille `bar` element
    showing the active model, provider, token usage, context-window
    percentage, compaction state, and key hints.

    **No process, no GenServer.** This module is a pure function over the
    model map. All state lives in the MVU model threaded through
    `Tau.TUI.App`; this module only reads it (OTP non-negotiables §3/#8).

    ## Segment layout

        model · provider | ↑N ↓N (cache N) | ctx NN% [████░] | <status> | <keys>

    When `context_window` is unknown (nil provider, nil window):
    - Falls back to compactor `:compaction_threshold_tokens` and renders `~NN%`.
    - When `context_tokens` is 0 (pre-first-turn), renders `ctx —`.

    ## Warning thresholds (D-165)

    Read once from `Application.get_env` at render time:
    - `:warn_threshold_pct`     — default 75 — renders `⚠` glyph.
    - `:critical_threshold_pct` — default 90 — renders `✖` glyph.

    Thresholds are read-only at boot; NOT runtime-mutable via `put_env`.
    """

    import Ratatouille.View

    @type model :: map()

    @doc """
    Build the segmented status bar for `model`.

    Returns a Ratatouille `bar` element. Pure — no side effects.
    """
    @spec render(model()) :: term()
    def render(model) do
      bar do
        label(content: render_text(model))
      end
    end

    @doc """
    Build the status bar text string for `model`.

    Separated from `render/1` so unit tests can assert on the string
    without a running Ratatouille runtime (D-162).
    """
    @spec render_text(model()) :: String.t()
    def render_text(model) do
      # D-162 (AC-H1 / SPEC-TUI-HEADLESS §5d): session_id segment MUST be first
      # so ~r/session:/ smoke-gate assertion matches. Mirrors the pre-rewrite
      # `"session: " <> model.session_id <> ...` rendering in app.ex.
      session_seg =
        case Map.get(model, :session_id) do
          nil -> nil
          sid -> "session: " <> sid
        end

      model_seg = model_segment(model)
      token_seg = cost_summary(usage_from(model))
      ctx_seg = context_segment(model)
      compaction_seg = compaction_segment(model)
      # D-171 (#341 PR-B / SPEC-PERMISSION-PROMPTS §7 AC-B5): always-visible
      # permissions-mode indicator. Shows the active mode (default/accept_edits/plan).
      mode_seg = permissions_mode_segment(model)
      hint_seg = hint_segment(model)

      segments =
        [session_seg, model_seg, token_seg, ctx_seg, compaction_seg, mode_seg, hint_seg]
        |> Enum.reject(&(is_nil(&1) or &1 == ""))

      # SPEC-CODING-AGENT §4 B1 (AC-9 regression): append agent segment when present.
      segments =
        case Map.get(model, :coding_agent_label) do
          nil -> segments
          label -> segments ++ ["agent: " <> label]
        end

      Enum.join(segments, " | ")
    end

    @doc """
    Compute the integer context percentage: `round(context_tokens / window * 100)`.

    Returns an integer in `0..100`, or `nil` when either argument is nil
    or the window is <= 0 (D-166 — never raises on bad input).

    Clamps to 100 when the ratio exceeds 1.0 (avoids >100% display bug).
    """
    @spec context_pct(non_neg_integer() | nil, pos_integer() | nil) :: non_neg_integer() | nil
    def context_pct(nil, _window), do: nil
    def context_pct(_tokens, nil), do: nil
    def context_pct(_tokens, window) when window <= 0, do: nil

    def context_pct(tokens, window) when is_integer(tokens) and is_integer(window) do
      max(0, min(round(tokens / window * 100), 100))
    end

    @doc """
    Classify a context-usage percentage as `:ok`, `:warn`, or `:critical`.

    - `nil` → `:ok` (no data yet, no warning)
    - `pct >= critical_threshold` → `:critical`
    - `pct >= warn_threshold` → `:warn`
    - otherwise → `:ok`

    Thresholds read from application env (read-only at call time — D-165):
    - `:critical_threshold_pct` (default 90)
    - `:warn_threshold_pct` (default 75)

    D-167 monotonicity: warn_level is non-decreasing within a usage
    percentage. `warn_level/1` returns the highest applicable level.
    """
    @spec warn_level(non_neg_integer() | nil) :: :ok | :warn | :critical
    def warn_level(nil), do: :ok

    def warn_level(pct) when is_integer(pct) do
      critical = Application.get_env(:tau, :critical_threshold_pct, 90)
      warn = Application.get_env(:tau, :warn_threshold_pct, 75)

      cond do
        pct >= critical -> :critical
        pct >= warn -> :warn
        true -> :ok
      end
    end

    @doc """
    Format token usage as a short summary string.

    Renders `↑N ↓N (cache N)` where N values are the raw token counts
    from the `usage` map. Returns `"—"` on nil or empty usage.

    Dollar cost is NOT shown — `Tau.Cost` is token-aggregation only
    (deferred per PR scope). See PR body §7.
    """
    @spec cost_summary(
            %{
              input_tokens: non_neg_integer(),
              output_tokens: non_neg_integer(),
              cache_read: non_neg_integer(),
              cache_write: non_neg_integer()
            }
            | nil
          ) :: String.t()
    def cost_summary(nil), do: "—"

    def cost_summary(%{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0}) do
      "—"
    end

    def cost_summary(%{
          input_tokens: inp,
          output_tokens: out,
          cache_read: cr,
          cache_write: _cw
        }) do
      "↑#{inp} ↓#{out} (cache #{cr})"
    end

    def cost_summary(_), do: "—"

    # --- private helpers ----------------------------------------------------

    defp model_segment(%{model: nil, provider: nil}), do: "no model"
    defp model_segment(%{model: m, provider: nil}) when is_binary(m), do: m
    defp model_segment(%{model: nil, provider: p}) when is_atom(p), do: inspect(p)

    defp model_segment(%{model: m, provider: p}) when is_binary(m) and is_atom(p) do
      short_provider = p |> Module.split() |> List.last() |> String.downcase()
      m <> " · " <> short_provider
    end

    defp model_segment(model) do
      m = Map.get(model, :model, "")
      if is_binary(m) and m != "", do: m, else: "no model"
    end

    defp usage_from(%{usage: u}) when is_map(u), do: u
    defp usage_from(_), do: nil

    defp context_segment(%{context_tokens: 0}), do: "ctx —"
    defp context_segment(%{context_tokens: nil}), do: "ctx —"

    defp context_segment(model) do
      tokens = Map.get(model, :context_tokens, 0)
      window = Map.get(model, :context_window)
      approximate = is_nil(window)

      effective_window =
        window ||
          Application.get_env(:tau, :compaction_threshold_tokens, 120_000)

      pct = context_pct(tokens, effective_window)
      level = warn_level(pct)
      glyph = warn_glyph(level)

      pct_str =
        if pct do
          prefix = if approximate, do: "~", else: ""
          prefix <> Integer.to_string(pct) <> "%"
        else
          "—"
        end

      bar_str =
        if pct do
          render_bar(pct)
        else
          ""
        end

      parts = ["ctx " <> pct_str <> bar_str]
      parts = if glyph != "", do: parts ++ [glyph], else: parts
      Enum.join(parts, " ")
    end

    defp render_bar(pct) when pct >= 0 and pct <= 100 do
      filled = round(pct / 100 * 8)
      empty = 8 - filled
      " [" <> String.duplicate("█", filled) <> String.duplicate("░", empty) <> "]"
    end

    defp render_bar(_), do: ""

    defp warn_glyph(:ok), do: ""
    defp warn_glyph(:warn), do: "⚠"
    defp warn_glyph(:critical), do: "✖"

    defp compaction_segment(%{compaction: :running}), do: "compacting…"
    defp compaction_segment(_), do: ""

    # D-171 (#341 PR-B / SPEC-PERMISSION-PROMPTS §7 AC-B5):
    # Always-visible permissions mode indicator. Renders "mode: <mode>".
    defp permissions_mode_segment(%{permissions_mode: mode}) when is_atom(mode) do
      "mode: " <> to_string(mode)
    end

    defp permissions_mode_segment(_), do: "mode: default"

    defp hint_segment(%{status: :idle}),
      do: "<Enter> submit · <Esc> clear · <Ctrl-C> quit"

    defp hint_segment(%{status: s}) when s in [:streaming, :sending],
      do: "<Enter> steer · <Alt+Enter> follow-up · <Esc> interrupt"

    defp hint_segment(%{status: s}) when is_binary(s),
      do: "<Enter> submit · <Esc> clear · <Ctrl-C> quit"

    defp hint_segment(_),
      do: "<Enter> steer · <Alt+Enter> follow-up · <Esc> interrupt"
  end
end
