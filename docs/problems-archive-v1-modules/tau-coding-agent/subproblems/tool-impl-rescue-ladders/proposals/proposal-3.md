---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Extract a `ToolResult` data type with distinct constructors for `:absent`, `:infrastructure_error`, and `:ok`

## Approach

Introduce a new private struct `Tau.CodingAgent.TauContext.Tools.ToolResult` (or
a plain module with constructor functions) with three constructors:
`ToolResult.ok/1`, `ToolResult.absent/2`, and `ToolResult.infrastructure_error/2`.
Each constructor builds a map with a fixed `"result_kind"` field. The three
rescue/catch sites are rewritten to use `ToolResult.infrastructure_error/2`; the
existing legitimate-absence paths use `ToolResult.absent/2`; success paths use
`ToolResult.ok/1`. The `encode/1` helper becomes `ToolResult.encode/1` and
consumes the struct. `session_cwd/1` returns `{:infrastructure_error, message}`
instead of `nil`, and the call site in `tau_memory_query/2` handles it explicitly.

## Rationale

Proposals 1 and 2 operate at opposite ends of the spectrum: Proposal 1 adds a
field to existing untyped maps; Proposal 2 removes all rescues. This proposal
takes a third axis — data-shape redesign — by introducing a typed result kind
at the boundary between the three helpers and their callers. The complecting is
removed not by deleting the rescue ladders or tagging their output ad-hoc, but by
making the distinction structurally enforced in the Elixir type system: a function
that returns `ToolResult.t()` cannot accidentally omit the kind. Future contributors
adding new rescue blocks must choose a constructor, making the distinction a pit
of success rather than a convention to remember. The D-035 contract (`{:ok,
String.t()}`) is preserved because `ToolResult.encode/1` still returns a JSON
string, and `result_kind` is an additive field in the wire format.

## Sketch

```elixir
# New private module: lib/tau/coding_agent/tau_context/tools/tool_result.ex
# (or defined inline via defmodule inside tools.ex if file count is a concern)

defmodule Tau.CodingAgent.TauContext.Tools.ToolResult do
  @moduledoc false

  @type kind :: :ok | :absent | :infrastructure_error
  @type t :: %{
    required(:result_kind) => String.t(),  # "ok" | "absent" | "infrastructure_error"
    required(:available) => boolean(),
    optional(:reason) => String.t(),
    optional(:error_class) => String.t()
  }

  @spec ok(map()) :: t()
  def ok(fields) when is_map(fields) do
    Map.merge(fields, %{"result_kind" => "ok", "available" => true})
  end

  @spec absent(String.t(), keyword()) :: t()
  def absent(reason, extra \\ []) when is_binary(reason) do
    Map.merge(
      Map.new(extra, fn {k, v} -> {Atom.to_string(k), v} end),
      %{"result_kind" => "absent", "available" => false, "reason" => reason}
    )
  end

  @spec infrastructure_error(String.t(), keyword()) :: t()
  def infrastructure_error(reason, extra \\ []) when is_binary(reason) do
    Map.merge(
      Map.new(extra, fn {k, v} -> {Atom.to_string(k), v} end),
      %{
        "result_kind" => "infrastructure_error",
        "available" => false,
        "error_class" => "infrastructure",
        "reason" => reason
      }
    )
  end
end

# tau_session_status/1 rescue block:
rescue
  e ->
    {:ok, encode(ToolResult.infrastructure_error(
      "snapshot error: " <> Exception.message(e)
    ))}
catch
  kind, reason ->
    {:ok, encode(ToolResult.infrastructure_error(
      "snapshot threw: #{inspect({kind, reason})}"
    ))}

# tau_session_status/1 legitimate-absence path:
{:error, :not_found} ->
  {:ok, encode(ToolResult.absent(
    "session #{id} not registered (already stopped?)",
    session_id: id
  ))}

# safe_memory_load/1 rescue:
rescue
  e -> {:error, {:infrastructure, "memory loader failed: " <> Exception.message(e)}}
catch
  k, r -> {:error, {:infrastructure, "memory loader threw: #{inspect({k, r})}"}}

# tau_memory_query/2 call site:
{:error, {:infrastructure, reason}} ->
  {:ok, encode(ToolResult.infrastructure_error(reason, query: query))}

{:error, reason} when is_binary(reason) ->
  {:ok, encode(ToolResult.absent(reason, query: query))}

# session_cwd/1:
defp session_cwd(session_id) do
  case Tau.Session.snapshot(session_id) do
    {:ok, %{cwd: cwd}} when is_binary(cwd) -> {:ok, cwd}
    _ -> {:absent, nil}
  end
rescue
  e -> {:infrastructure_error, Exception.message(e)}
catch
  _, _ -> {:infrastructure_error, "session_cwd threw"}
end
```

File changes:
- `lib/tau/coding_agent/tau_context/tools.ex` — three rescue sites rewritten.
- `lib/tau/coding_agent/tau_context/tools/tool_result.ex` — new private module
  (~40 lines). Alternatively, define the module inline in `tools.ex` to avoid
  a new file.

## Tradeoffs

### Strengths

- Structurally enforces the distinction: a developer adding a new rescue block
  is forced to choose `absent/2` or `infrastructure_error/2` — no accidental
  conflation is possible.
- Makes the wire format's `result_kind` field a first-class, inspectable artifact;
  coding-agent subprocesses gain a stable discriminator without relying on ad-hoc
  field presence.
- Full backwards-compatibility: `"available": false` is still present in all
  non-ok responses; `result_kind` is additive.
- Dialyzer can type-check the constructors; spec violations surface at compile
  time rather than at runtime.
- The D-035 `{:ok, String.t()}` contract is preserved.

### Weaknesses

- Introduces a new module and a new concept (`ToolResult`) that callers outside
  this file (the coding-agent subprocess protocol, SPEC-CODING-AGENT) must be
  aware of, even though it is private.
- The rescue ladders are still present — OTP non-negotiable §7 is still
  technically violated, same as Proposal 1.
- `result_kind` in the JSON wire format is undocumented in D-035; a SPEC
  amendment is needed to avoid it becoming an undocumented extension.
- The `session_cwd/1` call site change in `tau_memory_query/2` is more verbose
  than the current `|| nil` chain, which may be seen as an unnecessary increase
  in cognitive load for a private helper.
- Adding a file introduces a small coordination overhead (code review, test
  coverage expectation for the new module).

### Costs

- ~40 new lines in `tool_result.ex`; ~25 lines changed in `tools.ex`.
- A SPEC-CODING-AGENT §3 amendment should document `result_kind` semantics —
  this is not enforced as a blocker but is the responsible move.
- No new dependencies. No build impact.
- If the `ToolResult` module lives in a separate file, test coverage expectations
  may include a unit test of the constructors; these are trivial but take time.

## Dependencies

- None blocking. All three helpers are independent; the data-shape change can
  land in one PR.
- A SPEC-CODING-AGENT §3 amendment is recommended but not required by
  spec-before-code.md (D-035's `{:ok, String.t()}` return is unchanged).

## Confidence

medium — The data-type approach is well-established (cf. Rust `Result<Ok, Err>`
constructor pattern, Elixir `{:ok, _} | {:error, _}` conventions). Confidence is
medium rather than high because introducing a new module for what is ultimately a
JSON-building convention may be judged over-engineered relative to the problem
scope; a code reviewer familiar with the codebase may prefer Proposal 1's
lighter touch.

## Prior art / references

- Elixir `Ecto.Changeset` — typed result constructors that enforce invariants at
  the data-shape level rather than relying on conventions in callers.
- Rust `thiserror` crate — distinct error variants at the type level to make
  error-class handling structurally enforced.
- `Tau.Provider.Event` (referenced in `otp-non-negotiables.md`) — typed event
  structs that prevent ad-hoc field additions to provider event maps.
- JSON:API `errors[].status` — a standardised `result_kind`-equivalent in REST
  API design.
