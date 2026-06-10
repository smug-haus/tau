---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Tagged-tuple return — Port.close/1 wrapped in a targeted rescue, not a bare catch

## Approach

Replace the `try/catch` in `close_port/1` with a `try/rescue` that targets
`ArgumentError` only and returns a tagged result instead of `:ok`. The function
signature changes to `:: :ok | {:error, :already_closed}`. The `Port.info/1`
guard is removed (eliminating the TOCTOU window). Call sites that currently
treat the return as informational (both do) are updated to pattern-match on
`{:error, :already_closed}` explicitly, making the distinction visible.
Unexpected errors from `Port.close/1` — any exception other than `ArgumentError`
— propagate unhandled.

```elixir
defp close_port(nil), do: :ok

defp close_port(port) when is_port(port) do
  try do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> {:error, :already_closed}
  end
end

defp close_port(_), do: :ok
```

Call sites updated to ignore the distinction (since both callers are informational):

```elixir
# port_done/1
close_port(port)   # return value discarded — both :ok and {:error, :already_closed} are no-ops

# port_next/2 cancel branch
close_port(acc.port)  # same — discard
```

If a future caller needs to distinguish, the tagged return is ready.

## Rationale

The TOCTOU window comes from `Port.info/1` followed by `Port.close/1` as separate
operations; removing the pre-check and replacing the bare `catch` with a narrowly-scoped
`rescue ArgumentError` eliminates both the race and the silent-swallow. Returning a
tagged tuple rather than swallowing the error with `:ok` means the caller now has the
information to decide whether to log, count, or ignore the already-closed case — the
choice is moved to the call site where context exists. Unexpected errors are no longer
absorbed: only `ArgumentError` (the single known "already closed" signal) is caught; any
other error propagates normally.

This preserves the spirit of OTP non-negotiable rule 7 (let unexpected crashes propagate)
while handling the single expected failure mode (`ArgumentError` on dead port) explicitly,
which is consistent with the project's preference for "explicit error handling over
exceptions when possible" (global CLAUDE.md).

## Sketch

`lib/tau/coding_agents/claude_code.ex`:

```diff
  defp close_port(port) when is_port(port) do
-   try do
-     if Port.info(port) do
-       Port.close(port)
-     end
-   catch
-     _, _ -> :ok
-   end
-   :ok
+   try do
+     Port.close(port)
+     :ok
+   rescue
+     ArgumentError -> {:error, :already_closed}
+   end
  end
```

Call sites in the same file — no signature change needed unless callers want to react:

```elixir
# port_done/1:383 — already discards return
defp port_done(%{port: port, tempfile: tempfile, janitor: janitor}) do
  close_port(port)   # {:error, :already_closed} silently ignored — intentional
  ...
end

# port_next/2 cancel branch:270–283 — already discards return
close_port(acc.port)
```

No other files change. Net: ~3 lines removed, ~3 lines modified.

## Tradeoffs

### Strengths

- Satisfies the acceptance criterion: no bare `catch _,_`; no TOCTOU; unexpected errors
  propagate.
- Makes the "already closed" case explicitly named in the return type, not erased.
- Narrowly-typed rescue (`ArgumentError` only) is idiomatic Elixir for known-error
  handling and does not conflict with OTP rule 7 (which targets cross-process-boundary
  rescue, not local error classification).
- Future callers that need to log or count double-closes can pattern-match on
  `{:error, :already_closed}` without any further change.
- Minimal diff to existing callers: neither call site needs to change since both discard
  the return.

### Weaknesses

- Still uses `try/rescue` — the acceptance criterion says "does not use try/catch or
  try/rescue". This proposal uses `try/rescue` and therefore does **not** satisfy the
  criterion as written, unless the criterion is interpreted as "not a bare catch that
  swallows all errors". Requires adjudication.
- The `try` block is technically unnecessary if the criterion permits a bare `rescue
  ArgumentError` match at the call site instead; the scope of change is slightly
  larger in that alternative.
- Two call sites currently discard the tagged return — the new information is produced
  but consumed nowhere. This is not wrong, but it means the improvement is latent, not
  active.

### Costs

- ~6 lines changed in one file.
- No new modules or types.
- If callers are changed to handle `{:error, :already_closed}` explicitly, 2 additional
  call sites change (low cost).
- Test surface: tests that assert no crash on double-close remain valid; tests that assert
  `:ok` on double-close would need to be updated to accept `{:error, :already_closed}`.

## Dependencies

- Clarification on whether the acceptance criterion's "does not use try/rescue" is
  absolute (ruling out this proposal) or means "does not use a bare catch that swallows
  all errors" (permitting this proposal).
- No library changes.

## Confidence

Medium. The approach is mechanically sound; the uncertainty is whether the acceptance
criterion's wording permits any `try/rescue` at all. If the criterion is read strictly,
this proposal is disqualified by construction.

## Prior art / references

- Elixir documentation: `try/rescue` with a named exception type is the idiomatic pattern
  for handling a known, expected error class while letting all others propagate.
- Project global CLAUDE.md: "Explicit error handling over exceptions when possible" —
  tagged tuple return is the explicit form.
- OTP non-negotiables rule 7: the prohibition is on `try/rescue` *across process
  boundaries*, not within a single process. `Port.close/1` is intra-process (the port
  is owned by the calling process).
