defmodule Oban do
  @moduledoc """
  Minimal Oban stub satisfying `Code.ensure_loaded?(Oban)`.

  The full Oban package (distributed job queue backed by a database) is the
  intended distribution-boundary for the Worker fleet (D-S4,
  `docs/arch/04-software-architecture/supervision-tree.md` §6). This stub
  declares the module so the architecture boundary is structurally present
  and `Code.ensure_loaded?(Oban)` returns `true`, making the
  INV-DIST-WORKER-IDEMPOTENT invariant verifiable.

  When Oban is added as a real Hex dependency this file is removed; the
  real `Oban` module from the package supersedes it.

  See `docs/arch/04-software-architecture/worker-fleet.md` §8 (Distribution
  note) and `supervision-tree.md` §6 D-S4.
  """
end
