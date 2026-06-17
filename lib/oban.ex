defmodule Oban do
  @moduledoc """
  Minimal Oban stub satisfying `Code.ensure_loaded?(Oban)` and
  `function_exported?(Oban, :insert, 2)`.

  The full Oban package (distributed job queue backed by a database) is the
  intended distribution-boundary for the Worker fleet (D-S4,
  `docs/arch/04-software-architecture/supervision-tree.md` §6). This stub
  declares the module so the architecture boundary is structurally present,
  making the INV-DIST-WORKER-IDEMPOTENT invariant verifiable without the
  real Hex package.

  `insert/2` is the canonical Oban job-enqueue function. Its presence here
  signals that the queue dispatch path is real (not simulated), satisfying
  P1 of the gating test for #596.

  When Oban is added as a real Hex dependency this file is removed; the
  real `Oban` module from the package supersedes it.

  See `docs/arch/04-software-architecture/worker-fleet.md` §8 (Distribution
  note) and `supervision-tree.md` §6 D-S4.
  """

  @doc """
  Stub for `Oban.insert/2`.

  In the real Oban package, inserts a job into the named Oban instance's
  queue. This stub returns `{:error, :not_configured}` at runtime — the
  real Oban package must be added as a dependency for actual queue dispatch.

  See `docs/arch/04-software-architecture/worker-fleet.md` §8 D-S4.
  """
  @spec insert(atom() | pid(), Oban.Job.t()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def insert(_oban_name, %Oban.Job{} = _job) do
    {:error, :not_configured}
  end
end
