---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Runtime capability probe — adapters self-verify via a mandatory `probe/0` callback

## Approach

Add a mandatory `probe/0` callback to `Tau.Provider` that returns
`{:ok, verified_capabilities}` or `{:error, [failed_flags]}`. Each adapter
implements `probe/0` to exercise its own decode path against a minimal canned
input (no real network call — a fixture struct that simulates a provider
response chunk). `probe/0` is called at application startup (and optionally
on demand) by a new `Tau.Provider.Registry` GenServer; it replaces the static
`capabilities/0` return value with a runtime-verified map. Adapters that fail
their probe have the failing flags demoted to `false` at runtime, with a
startup log warning. `capabilities/0` is retained for the static declared
intent but the Registry's verified map is what callers use.

## Rationale

Static maps and doc contracts both rely on human discipline. A runtime probe
breaks the complect at the only layer where it cannot be bypassed: execution.
If Bedrock's decode path does not emit `ThinkingStart`, `probe/0` running
a fixture chunk through `decode_anthropic_event/2` will not observe the event,
and the `thinking` flag is demoted at runtime — without any human needing to
read the adapter. This scales to new flags and new adapters without requiring
a doc update: the probe is the contract. Callers query the Registry instead of
calling `adapter.capabilities()` directly, so the verified map is always current.

## Sketch

```elixir
# lib/tau/provider.ex — new mandatory callback

@doc """
Exercises the adapter's own decode path against a provider-specific canned
fixture and returns the verified capability flags.

The probe MUST NOT make any network call. It runs against in-process fixture
data (a minimal simulated provider response chunk). It returns:

  * `{:ok, capabilities()}` — all declared capabilities verified.
  * `{:error, failed :: [atom()]}` — one or more declared capabilities could
    not be verified. The registry demotes the failing flags to `false` at
    startup.

Probe failures are logged at `:warning` level. The adapter continues to
operate; unverified flags are conservatively set to `false`.
"""
@callback probe() :: {:ok, capabilities()} | {:error, [atom()]}
```

```elixir
# lib/tau/provider/registry.ex — new supervised GenServer

defmodule Tau.Provider.Registry do
  @moduledoc """
  Supervised GenServer that probes all configured adapters at startup and
  maintains a runtime-verified capability map per adapter.

  Callers use `Tau.Provider.Registry.capabilities/1` instead of
  `adapter.capabilities/0` for the verified map.
  """
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec capabilities(module()) :: Tau.Provider.capabilities()
  def capabilities(adapter) do
    GenServer.call(__MODULE__, {:capabilities, adapter})
  end

  @impl true
  def init(_opts) do
    adapters = Application.get_env(:tau, :providers, [])
    verified = Map.new(adapters, fn mod -> {mod, probe_adapter(mod)} end)
    {:ok, verified}
  end

  @impl true
  def handle_call({:capabilities, adapter}, _from, verified) do
    caps = Map.get(verified, adapter, adapter.capabilities())
    {:reply, caps, verified}
  end

  defp probe_adapter(mod) do
    declared = mod.capabilities()
    case mod.probe() do
      {:ok, verified} ->
        verified
      {:error, failed} ->
        Logger.warning("#{inspect(mod)} probe failed for flags: #{inspect(failed)}; demoting to false")
        Enum.reduce(failed, declared, fn flag, acc -> Map.put(acc, flag, false) end)
    end
  end
end
```

```elixir
# lib/tau/providers/bedrock.ex — example probe implementation

def probe do
  # Simulate a ThinkingStart chunk through decode_anthropic_event/2
  thinking_fixture = %{
    "type" => "content_block_start",
    "content_block" => %{"type" => "thinking", "thinking" => ""}
  }
  case decode_anthropic_event(thinking_fixture, %{}) do
    {events, _} when is_list(events) ->
      has_thinking = Enum.any?(events, &match?(%Tau.Provider.Event.ThinkingStart{}, &1))
      if has_thinking do
        {:ok, capabilities()}
      else
        {:error, [:thinking]}
      end
    _ ->
      {:error, [:thinking]}
  end
  # prompt_caching probe: check function_exported? (already verifiable statically)
  # Can be added as a second clause
end
```

```elixir
# Caller migration — minimal:
# Before:
adapter.capabilities().thinking
# After:
Tau.Provider.Registry.capabilities(adapter).thinking
```

Existing `capabilities/0` on each adapter is retained for documentation
purposes (declares intent) but is no longer the authoritative source for
feature gating.

## Tradeoffs

### Strengths

- The only proposal that mechanically catches a lying `decode_anthropic_event`
  path at runtime, without requiring humans to read code.
- Self-healing: if an adapter's decode is fixed in a later PR, the probe
  automatically elevates the flag on next startup — no separate flag PR needed.
- Scales to new flags without doc updates: add a new fixture to `probe/0`.
- Directly satisfies "observable guarantee" in the acceptance criterion — the
  guarantee is verified, not just declared.
- Probe results can be exposed via telemetry for observability.

### Weaknesses

- `probe/0` is mandatory: adding it to eleven adapters is a significant
  migration. The probe must be adapter-specific (fixture format differs per
  provider), making it non-trivial to write correctly.
- Fixture fidelity problem: a probe that passes a minimal fixture through
  the decode path only proves the path exists for that fixture shape — a
  decode path that happens to emit `ThinkingStart` for the fixture but not
  for real provider chunks would pass the probe and still mislead callers.
- Adds startup latency: all adapters probe on startup (in-process, so fast,
  but still non-zero).
- New process `Tau.Provider.Registry` in the supervision tree adds complexity;
  caller migration from `adapter.capabilities()` to `Registry.capabilities(adapter)`
  is a widespread change.
- Probe infrastructure can drift from real usage: if `decode_anthropic_event`
  changes its fixture handling but probes aren't updated, probes pass falsely.
- API-breaking: callers should use `Registry.capabilities/1` not
  `adapter.capabilities/0` — this is a significant coordination change.

### Costs

- New files: `lib/tau/provider/registry.ex` (~80 LOC),
  `test/tau/provider/registry_test.exs`.
- Modify `lib/tau/provider.ex`: add `probe/0` callback to `@callback` list.
- Modify all eleven adapters: implement `probe/0` with adapter-specific fixtures.
- Modify `lib/tau/application.ex`: add `Tau.Provider.Registry` to supervision tree.
- Modify all callers of `capabilities/0`: route through Registry or use a
  compatibility shim.
- Fixture maintenance: each adapter's `probe/0` must be updated when the
  provider's response format changes.

## Dependencies

- All adapters must implement `probe/0` before `Tau.Provider.Registry` can be
  started with a complete verified map.
- `Tau.Provider.Registry` must be started before any caller invokes
  `Registry.capabilities/1`; supervision order must be updated.
- Can be staged: ship `probe/0` as `@optional_callbacks` initially; Registry
  falls back to `adapter.capabilities()` for adapters that don't yet have a probe.

## Confidence

Low. The fixture-fidelity problem is significant: a probe that only checks
the static module structure (e.g. `function_exported?`) is equivalent to
Proposal 1 with more machinery. A probe that exercises real decode paths
requires non-trivial fixture engineering per adapter and ongoing maintenance.
Confidence rises substantially if the scope is narrowed to a "structural probe
only" (function_exported? checks) — but then Proposal 1 achieves the same
result more simply.

## Prior art / references

- Erlang `:application` and `:health_check` pattern: modules self-report health
  via a callback at startup.
- PostgreSQL `pg_hba_file_rules` self-test: the auth config is verified at
  reload, not just at write time.
- Elixir `Nimble.Options` schema validation: validating a map's values against
  declared constraints at use-time rather than definition-time.
- Tau `Tau.CircuitBreaker` (SPEC-CIRCUIT-BREAKER): uses ETS-owner lifecycle
  probe as a pattern for startup-time state verification.
