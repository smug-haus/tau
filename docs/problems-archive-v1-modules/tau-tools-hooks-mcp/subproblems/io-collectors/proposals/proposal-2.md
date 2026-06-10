---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: iolist accumulation + in-place cap guards — no new module

## Approach

Fix all three sites in place, without extracting a shared module. At each site:
(1) replace `acc <> data` with list prepend (`[data | acc]`) and
`IO.iodata_to_binary/1` at the terminal clause, eliminating O(n²) binary
concatenation; (2) add an in-loop byte-size guard after every prepend that calls
`close_if_open(port)` and exits when the accumulated size exceeds the cap; (3)
replace every `try/catch` around `Port.close/1` with a single private helper
`close_if_open/1` local to each module. The three modules remain independent;
the change is behaviour-correcting (fixes OOM risk) but not API-breaking.

## Rationale

The complecting hypothesis is that accumulation strategy and termination policy
are woven: the accumulation loop simply grows the binary and the cap is applied
only later. This proposal decomplects by embedding the cap check as a loop
invariant at each site, making the termination decision local to the same clause
that grows the buffer. A shared module is not required for decomplecting: the
complect is strategy-and-lifecycle coupling, which is broken by co-locating the
cap guard with the accumulation expression, not by extraction. Keeping the fix
in-place avoids introducing an additional indirection layer and a new namespace
the three subsystems must depend on.

## Sketch

`local.ex` — revised `collect_port/4` (adds `max_bytes` param):

```elixir
# @max_bytes already defined at module level via bash.ex / builtin module attr
defp collect_port(port, acc, deadline, max_bytes) do
  receive do
    {^port, {:data, data}} ->
      acc = [data | acc]
      if IO.iodata_length(acc) >= max_bytes do
        close_if_open(port)
        {:ok, IO.iodata_to_binary(acc) |> binary_part(0, max_bytes), :cap_reached}
      else
        collect_port(port, acc, deadline, max_bytes)
      end

    {^port, {:exit_status, n}} ->
      {:ok, IO.iodata_to_binary(acc), n}
  after
    remaining_or_inf(deadline) ->
      close_if_open(port)
      {:error, :timeout}
  end
end

defp close_if_open(port) do
  if Port.info(port) != nil, do: Port.close(port)
  :ok
end
```

`hooks/shell.ex` — revised `collect/4` (adds `max_bytes`; hooks define a module attr):

```elixir
@max_output_bytes 32_768  # 32 KiB — same policy as Bash tool

defp collect(port, acc, timeout_ms, max_bytes \\ @max_output_bytes) do
  receive do
    {^port, {:data, d}} ->
      acc = [d | acc]
      if IO.iodata_length(acc) >= max_bytes do
        close_if_open(port)
        {:ok, IO.iodata_to_binary(acc) |> binary_part(0, max_bytes), :cap_reached}
      else
        collect(port, acc, timeout_ms, max_bytes)
      end

    {^port, {:exit_status, n}} ->
      {:ok, IO.iodata_to_binary(acc), n}
  after
    timeout_ms ->
      close_if_open(port)
      {:error, :timeout}
  end
end

defp close_if_open(port) do
  if Port.info(port) != nil, do: Port.close(port)
  :ok
end
```

`mcp/transport/stdio.ex` — `recv/2` partial guard (line-framed; cap is on
partial line length, not full message stream):

```elixir
@max_partial_bytes 65_536  # 64 KiB partial-line cap

{^port, {:data, {:noeol, partial}}} ->
  new_partial = state.partial <> partial
  if byte_size(new_partial) >= @max_partial_bytes do
    {:error, {:partial_overflow, byte_size(new_partial)}}
  else
    recv(%{state | partial: new_partial}, timeout)
  end
```

`close/1` in `stdio.ex`:

```elixir
def close(%{port: port}) do
  if Port.info(port) != nil, do: Port.close(port)
  :ok
end
```

## Tradeoffs

### Strengths

- Zero new modules, zero new namespaces; the three modules remain independently
  readable without cross-referencing a shared dependency.
- Simultaneously fixes the O(n²) concatenation with iolist accumulation —
  Proposal 1 defers this.
- In-place cap guard is immediately visible alongside the accumulation expression;
  the complect is broken exactly where it lives.
- Lower reviewer surface area: diffs are confined to three files.
- `close_if_open/1` is a one-line private helper at each module; no shared
  library knowledge required.

### Weaknesses

- The same `close_if_open/1` helper is repeated in three modules (3 × 2 lines);
  this is minor duplication, but it is not a single source of truth.
- Without a shared type for the cap result, each site can diverge on what
  `:cap_reached` / `{:partial_overflow, n}` means to callers; the contract
  remains per-site.
- `IO.iodata_length/1` traverses the iolist on every chunk to compute cumulative
  length; for very large outputs this is O(n) per iteration (though still far
  better than O(n²) binary concat). A running byte counter sidestep exists but
  adds a parameter.
- Testing requires three separate test cases to assert cap behaviour; a single
  shared module test would cover all three with one case.
- The iolist path requires `IO.iodata_to_binary/1` at the terminal clause, which
  allocates a single large binary at exit; peak memory is still O(max_bytes),
  the same as before, but intermediate memory is lower.

### Costs

- Three files edited; no new files created.
- `collect_port/3` in `local.ex` becomes `collect_port/4` — one internal
  call-site change.
- `collect/3` in `hooks/shell.ex` gains an optional fourth parameter — backward
  compatible within the module.
- Three new `@max_output_bytes` / `@max_partial_bytes` module attributes to
  decide and document.
- Existing tests that exercise `collect_port` output truncation must be verified
  to still pass with the earlier (mid-loop) truncation point.

## Dependencies

- `@max_bytes` currently lives implicitly via `Bash.truncate/3`; it must be
  made explicit as a module attribute in `local.ex` and threaded into
  `collect_port`.
- `hooks/shell.ex` has no cap today; the cap value must be decided and
  documented in a module attribute or in the hook-runner opts.

## Confidence

high — every change is self-contained within the target file, uses only stdlib
functions (`IO.iodata_length/1`, `IO.iodata_to_binary/1`, `Port.info/1`), and
the pattern is idiomatic Elixir for bounded accumulation. Prior art is abundant.
A prototype at any one site would immediately confirm the approach at the other
two.

## Prior art / references

- `IO.iodata_to_binary/1` accumulation pattern: Elixir documentation, "Building
  strings efficiently" section.
- `IO.iodata_length/1` for running length without materialisation: used in
  Phoenix's `Plug.Conn` body accumulation guard.
- `Port.info/1 != nil` liveness idiom: Elixir `Port` module docs.
- OTP "bound-at-receive" pattern: documented in Cesarini & Vinoski
  "Designing for Scalability with Erlang/OTP", §6.2.
