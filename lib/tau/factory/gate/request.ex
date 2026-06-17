defmodule Tau.Factory.Gate.Request do
  @moduledoc """
  The input record passed to `Tau.Factory.Gate.run/1`.

  ## Fields (pinned in SPEC-FACTORY-GATE §4 B1 — see §4 amendment PR #464)

  - `:unit`        — the PR/unit identifier string (e.g. `"pr-464"`).
  - `:diff`        — the unified diff string between `merge_base` and `hash`
                     (the implementer's change set).
  - `:frozen_paths` — `MapSet.t(String.t())` of declared gating-test paths
                     (the frozen oracle-separation boundary; D-304).
  - `:policy_pin`  — map of policy overrides pinned at admission (HR-8).
                     Recognised keys:
                       - `:gate_manifest` — the requested half list (the engine
                         floor `[:mutation, :critic, :reviewer]` is re-asserted
                         by `compose/1` regardless; D-354).
                       - `:gate_concurrency` — `Task.Supervisor` fan-out width.
                       - `:gate_timeout` — per-half timeout (ms).
                       - `:oracle` — deterministic oracle override map, e.g.
                         `%{critic: :pass, reviewer: :pass}`. When present,
                         `Gate.Oracle` uses this value instead of spawning a
                         real LLM worker (the hermetic-test seam; §4 B1/B2
                         amendment).
  - `:workspace`   — absolute path to the host-isolated git workspace the
                     engine-owned mutation half runs in (D-309 / C201).
  - `:merge_base`  — the git ref / SHA representing the pre-implementer state
                     (`git merge-base origin/main HEAD`); the mutation half
                     reverts `tracked ∖ frozen_paths` to this ref (D-306).
  - `:hash`        — the HEAD SHA of the implementer's commit (used as the
                     `(hash, run, half)` coordinate in the Ledger).
  - `:run`         — the run identifier string (e.g. `"run-1"`); together with
                     `:hash` forms the Ledger coordinate (D-335).
  - `:ledger`      — `GenServer.server()` reference to the active
                     `Tau.Factory.Ledger.Writer` (the gate appends its verdict
                     to L via WAL-before-ack; D-335).
  - `:language`    — the language atom for `Tau.Factory.Toolchain` dispatch
                     (D-S2 polyglot seam). Defaults to `:elixir`. Must be a
                     registered language atom (`Toolchain.for/1`); unknown atoms
                     fail the mutation half closed.
  """

  @type t :: %__MODULE__{
          unit: String.t(),
          diff: String.t(),
          frozen_paths: MapSet.t(String.t()),
          policy_pin: map(),
          workspace: String.t(),
          merge_base: String.t(),
          hash: String.t(),
          run: String.t(),
          ledger: GenServer.server(),
          language: atom()
        }

  @enforce_keys [
    :unit,
    :diff,
    :frozen_paths,
    :policy_pin,
    :workspace,
    :merge_base,
    :hash,
    :run,
    :ledger
  ]
  defstruct [
    :unit,
    :diff,
    :frozen_paths,
    :policy_pin,
    :workspace,
    :merge_base,
    :hash,
    :run,
    :ledger,
    language: :elixir
  ]
end
