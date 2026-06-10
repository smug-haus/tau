---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Tagged-error envelope — add an `"error_class"` field to distinguish infrastructure failures from legitimate absences

## Approach

Keep the three `rescue`/`catch` ladders structurally in place but change what
they return: when an infrastructure exception is caught, encode an additional
`"error_class": "infrastructure"` field alongside `"available": false`. Legitimate
absences (`:not_found`, `nil` session_id, `Tau.Memory.Loader` not available) keep
the current shape — `"available": false` with no `error_class` field (or
explicitly `"error_class": "absent"`). Callers in the coding-agent subprocess can
now branch on this field. `session_cwd/1` changes similarly: instead of returning
bare `nil` on rescue, it returns a 2-tuple `{:error, :infrastructure}` that the
call site in `tau_memory_query/2` tests explicitly before falling through to
`File.cwd!/0`.

## Rationale

The complecting hypothesis identifies one concrete confusion: both error classes
reach the caller via the same `{"available": false}` shape. This proposal
decomplects them at the data-shape level — the existing rescue ladder stays but
its output changes. It is the smallest change that satisfies the acceptance
criterion ("structurally distinguishable"). It does not change the public D-035
contract (callers still get `{:ok, JSON}`) and does not change how OTP supervises
the subsystem. A subprocess coding agent can inspect `error_class` and decide to
retry vs accept; the MCP wire format gains a documented extension point without
breaking existing callers that ignore the new field.

## Sketch

```elixir
# tools.ex — tau_session_status/1 rescue block becomes:
rescue
  e ->
    {:ok,
     encode(%{
       "available" => false,
       "error_class" => "infrastructure",
       "reason" => "snapshot error: " <> Exception.message(e)
     })}
catch
  kind, reason ->
    {:ok,
     encode(%{
       "available" => false,
       "error_class" => "infrastructure",
       "reason" => "snapshot threw: #{inspect({kind, reason})}"
     })}

# safe_memory_load/1 rescue block becomes:
rescue
  e -> {:error, {:infrastructure, "memory loader failed: " <> Exception.message(e)}}
catch
  kind, reason ->
    {:error, {:infrastructure, "memory loader threw: #{inspect({kind, reason})}"}}

# tau_memory_query/2 call site — pattern match on the tagged error:
{:error, {:infrastructure, reason}} ->
  {:ok, encode(%{"available" => false, "error_class" => "infrastructure",
                 "reason" => reason, "query" => query})}

{:error, reason} when is_binary(reason) ->
  {:ok, encode(%{"available" => false, "reason" => reason, "query" => query})}

# session_cwd/1 returns {:error, :infrastructure} instead of nil:
defp session_cwd(session_id) do
  case Tau.Session.snapshot(session_id) do
    {:ok, %{cwd: cwd}} when is_binary(cwd) -> {:ok, cwd}
    _ -> {:ok, nil}
  end
rescue
  _ -> {:error, :infrastructure}
catch
  _, _ -> {:error, :infrastructure}
end

# tau_memory_query/2 cwd resolution becomes:
cwd =
  Map.get(state, :cwd) ||
    (case Map.get(state, :session_id) && session_cwd(Map.get(state, :session_id)) do
       {:ok, cwd} -> cwd
       {:error, :infrastructure} -> nil   # still falls through; now traceable
       _ -> nil
     end) ||
    File.cwd!()
```

No new modules. No file moves. Three call sites change; the `encode/1` helper
and the D-035 `{:ok, String.t()}` return type are both preserved.

## Tradeoffs

### Strengths

- Satisfies the acceptance criterion with the minimum diff surface: three
  `rescue` blocks and two call sites change, nothing else.
- Backwards-compatible with existing coding-agent subprocess code that does not
  yet inspect `error_class` — it is an additive field.
- Preserves D-035's `{:ok, String.t()}` public contract verbatim.
- `session_cwd/1` now returns a tagged tuple that is explicitly handled, so a
  session-lookup crash no longer silently falls through to `File.cwd!/0` without
  a visible decision.

### Weaknesses

- Does not remove the `rescue`/`catch` ladders — OTP non-negotiable §7 ("Let it
  crash; supervise; restart") is still violated in principle. Infrastructure
  errors are now observable but they are still absorbed, not propagated.
- `session_cwd/1`'s `{:error, :infrastructure}` case still silently falls through
  to `File.cwd!/0` in `tau_memory_query/2` — the difference is now that the
  decision is explicit in code, but the behaviour for a caller that does not
  handle the error branch is identical to the status quo.
- Adds a coordination burden: future callers must know to check `error_class`, and
  new `rescue` blocks added by other contributors may forget to add it.
- No telemetry: infrastructure errors are now visible in the JSON but not logged
  or counted anywhere; silent crashes remain invisible in production metrics.
- `"error_class"` is an ad-hoc convention, not enforced by a type.

### Costs

- Diff is small: ~20 lines changed across three helpers and two call sites.
- No new dependencies, no new modules.
- The coding-agent subprocess protocol gains an undocumented extension; no SPEC
  amendment is required by out-of-scope rules, but one should be filed for §4
  D-035 to capture the new field semantics.

## Dependencies

- None: each of the three helpers is independent; the change is self-contained.
- A SPEC-CODING-AGENT §3 amendment noting the `error_class` field would be good
  practice but is not enforced as a blocker by spec-before-code.md (the D-035
  public contract — `{:ok, String.t()}` — is unchanged).

## Confidence

medium — The change is simple and bounded, but the fact that it leaves the rescue
ladders in place means it does not fully satisfy the spirit of OTP non-negotiable
§7. Confidence would rise to high if the acceptance criterion is read strictly as
"structurally distinguishable response shapes", and would lower to low if the
criterion is interpreted as "callers can rely on the OTP process model instead of
pre-emptive rescue".

## Prior art / references

- JSON:API `errors[].status` convention — structurally tagged error fields in
  JSON payloads that coexist with success responses.
- Elixir `{:error, {:tag, detail}}` pattern used throughout `Tau.CircuitBreaker`
  and `Tau.Memory.Store` for multi-class error discrimination.
- D-035 comment in `tools.ex` `@moduledoc`: "Every public function in this module
  catches its own errors and returns a tagged tuple" — this proposal extends that
  to the JSON envelope itself.
