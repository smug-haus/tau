defmodule Tau.Factory.MergeQueuePropertyTest do
  @moduledoc """
  Gating property test for D-341 — fair FIFO+aging wait-queue (AC-6,
  SPEC-FACTORY-MERGE §6).

  D-341 requires `Tau.Factory.Merge.Queue` (C4) with:

    effective_priority(seq, restale_count) = seq − aging_weight · restale_count

  A unit re-staled k times gets a lower (numerically smaller) effective_priority
  than a newcomer at seq+1 after enough re-stales (no-starvation floor).

  The audit (issue #625) found that lib/tau/factory/merge/queue.ex (C4) does
  NOT exist, and MergeAuthority uses plain FIFO (pure tail-append + head-dequeue)
  with no aging. Under the many-small-PR workload (Q-L1), a stream of small fast
  PRs can indefinitely defer a re-staled large branch — falsifying D-341.

  ## Fail-before validity

  Tau.Factory.Merge.Queue does not exist. Every Queue.* call below is an
  UndefinedFunctionError (or a compile-time module-not-loaded error), which is
  the correct red-before-green state for oracle separation.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property
  @moduletag :d_341

  alias Tau.Factory.Merge.Queue

  # P-Q-1: effective_priority/1 returns a number; higher restale_count yields <= priority
  property "D-341 P-Q-1: effective_priority/1 numeric; aging lowers priority" do
    check all(
      seq <- StreamData.positive_integer(),
      restale_count <- StreamData.positive_integer()
    ) do
      fresh = %{id: "fresh", seq: seq, restale_count: 0}
      restaled = %{id: "restaled", seq: seq, restale_count: restale_count}

      fp = Queue.effective_priority(fresh)
      rp = Queue.effective_priority(restaled)

      assert is_number(fp), "effective_priority/1 must return a number"
      assert is_number(rp), "effective_priority/1 must return a number"

      assert rp <= fp,
             "D-341: restale_count=#{restale_count} must yield priority ≤ restale_count=0. " <>
               "Got restaled=#{rp}, fresh=#{fp}"
    end
  end

  # P-Q-2: strictly monotone — each additional restale strictly decreases priority
  property "D-341 P-Q-2: effective_priority strictly decreases with restale_count" do
    check all(
      seq <- StreamData.positive_integer(),
      k <- StreamData.positive_integer()
    ) do
      unit_k = %{id: "u", seq: seq, restale_count: k}
      unit_k1 = %{id: "u", seq: seq, restale_count: k + 1}

      pk = Queue.effective_priority(unit_k)
      pk1 = Queue.effective_priority(unit_k1)

      assert pk1 < pk,
             "D-341: priority must be strictly decreasing; " <>
               "at seq=#{seq}, k=#{k}: priority(k)=#{pk}, priority(k+1)=#{pk1}; " <>
               "expected #{pk1} < #{pk}. Pure FIFO (aging_weight=0) violates this."
    end
  end

  # P-Q-3: aging bound — a unit re-staled k_bound times beats a newcomer at seq+1
  property "D-341 P-Q-3: aging bound — re-staled unit beats newcomer at seq+1" do
    check all(seq <- StreamData.integer(1..1_000)) do
      newcomer = %{id: "newcomer", seq: seq + 1, restale_count: 0}
      newcomer_p = Queue.effective_priority(newcomer)

      # Conservative upper bound: any legitimate aging_weight >= 1 satisfies this.
      restaled = %{id: "restaled", seq: seq, restale_count: 1_000}
      restaled_p = Queue.effective_priority(restaled)

      assert restaled_p < newcomer_p,
             "D-341: re-staled unit (seq=#{seq}, k=1000) must beat newcomer (seq=#{seq + 1}). " <>
               "Got restaled=#{restaled_p}, newcomer=#{newcomer_p}. " <>
               "Pure FIFO falsifies this (restaled=#{seq} > newcomer=#{seq + 1})."
    end
  end

  # P-Q-4: dequeue_batch/1 selects minimum effective_priority (highest urgency)
  property "D-341 P-Q-4: dequeue_batch selects minimum-priority unit first" do
    check all(
      n <- StreamData.integer(2..8),
      seqs <- StreamData.list_of(StreamData.positive_integer(), length: n),
      restales <- StreamData.list_of(StreamData.non_negative_integer(), length: n)
    ) do
      units =
        [seqs, restales]
        |> Enum.zip()
        |> Enum.with_index(1)
        |> Enum.map(fn {{seq, rc}, idx} -> %{id: "u#{idx}", seq: seq, restale_count: rc} end)

      queue = Queue.new(units)
      {batch, _remaining} = Queue.dequeue_batch(queue)

      dequeued_ids = MapSet.new(batch, & &1.id)
      remaining = Enum.reject(units, &MapSet.member?(dequeued_ids, &1.id))

      for d <- batch, r <- remaining do
        dp = Queue.effective_priority(d)
        rp = Queue.effective_priority(r)

        assert dp <= rp,
               "D-341: dequeue selected #{d.id} (prio=#{dp}) ahead of #{r.id} (prio=#{rp}); " <>
                 "dequeue must select minimum-priority (highest urgency) first."
      end
    end
  end

  # P-Q-5: enqueue/2 stamps monotone seq; re-enqueue increments restale_count
  # and preserves enqueued_at (total wait-time must not reset on restale)
  property "D-341 P-Q-5: enqueue stamps monotone seq; restale preserves enqueued_at" do
    check all(n <- StreamData.integer(1..5)) do
      units_in = Enum.map(1..n, fn i -> %{id: "u#{i}"} end)
      q0 = Queue.empty()

      {q1, stamped} =
        Enum.reduce(units_in, {q0, []}, fn u, {q, acc} ->
          {q2, s} = Queue.enqueue(q, u)
          {q2, acc ++ [s]}
        end)

      # Every stamped unit must carry :seq
      for u <- stamped do
        assert Map.has_key?(u, :seq),
               "D-341: enqueue/2 must stamp :seq; unit #{u.id} is missing it."
      end

      # Seq must be monotone-increasing
      seqs = Enum.map(stamped, & &1.seq)
      assert seqs == Enum.sort(seqs),
             "D-341: :seq must be monotone-increasing in enqueue order. Got #{inspect(seqs)}"

      # Re-enqueue: restale_count increments, enqueued_at preserved
      Enum.each(stamped, fn u ->
        original_at = Map.get(u, :enqueued_at)
        {_q2, restaled} = Queue.enqueue(q1, u)

        assert Map.get(restaled, :restale_count, 0) > Map.get(u, :restale_count, 0),
               "D-341: re-enqueue must increment :restale_count for unit #{u.id}."

        if original_at do
          assert Map.get(restaled, :enqueued_at) == original_at,
                 "D-341: re-enqueue must preserve :enqueued_at for unit #{u.id}."
        end
      end)
    end
  end
end
