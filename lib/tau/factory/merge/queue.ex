defmodule Tau.Factory.Merge.Queue do
  @moduledoc """
  C4 — Pure fair wait-queue for `Tau.Factory.MergeAuthority`.

  Implements FIFO sequencing with aging by `restale_count` to enforce D-341
  (LIV-2): no green+fresh PR starves behind a stream of small fast PRs.

  ## Priority model

      effective_priority(seq, restale_count) = seq - aging_weight * restale_count

  Lower numeric value = higher urgency (admitted to the train first). A unit
  re-staled `k` times accumulates aging credit; after bounded re-stales its
  effective_priority drops below any newcomer's, guaranteeing eventual admission.

  `aging_weight = 1` satisfies the SPEC constraint that `aging_weight >= 1`.

  ## Properties enforced

  - P-Q-1: `effective_priority/1` is numeric; restaling lowers priority.
  - P-Q-2: priority strictly decreases with each additional restale.
  - P-Q-3: after enough restales, a unit beats a newcomer with a later seq.
  - P-Q-4: `dequeue_batch/1` selects the batch of units with minimum priority.
  - P-Q-5: `enqueue/2` stamps monotone `:seq`; re-enqueue increments
    `:restale_count` and preserves `:enqueued_at`.

  No process. Stateless pure functions only. Properties before examples
  (`test/tau/factory/merge_queue_property_test.exs`).
  """

  @aging_weight 1

  @opaque t :: %__MODULE__{entries: [map()], next_seq: non_neg_integer()}

  defstruct entries: [], next_seq: 0

  @doc """
  Returns an empty queue.
  """
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc """
  Builds a queue from an existing list of units.

  Units that already carry a `:seq` key are inserted as-is (their seq is
  respected for priority ordering). Units without `:seq` are stamped with
  monotone seqs starting after any pre-existing maximum seq in the list.

  Used when `MergeAuthority` rebuilds its wait-queue from the Ledger on
  restart (`C218`).
  """
  @spec new([map()]) :: t()
  def new(units) when is_list(units) do
    max_seq =
      Enum.reduce(units, -1, fn u, acc ->
        max(acc, Map.get(u, :seq, -1))
      end)

    next_seq = max_seq + 1

    {entries, final_seq} =
      Enum.map_reduce(units, next_seq, fn u, seq ->
        if Map.has_key?(u, :seq) do
          {u, seq}
        else
          stamped =
            u
            |> Map.put(:seq, seq)
            |> Map.put_new(:restale_count, 0)
            |> Map.put_new(:enqueued_at, System.monotonic_time(:millisecond))

          {stamped, seq + 1}
        end
      end)

    %__MODULE__{entries: entries, next_seq: final_seq}
  end

  @doc """
  Enqueues a unit into the queue.

  - If the unit has no `:seq`, stamps it with the next monotone seq and sets
    `:restale_count` to `0` and `:enqueued_at` to now (first entry).
  - If the unit already has a `:seq` (re-enqueue / restale), increments
    `:restale_count` and preserves `:enqueued_at` (total wait must not reset).

  Returns `{updated_queue, stamped_unit}`.
  """
  @spec enqueue(t(), map()) :: {t(), map()}
  def enqueue(%__MODULE__{entries: entries, next_seq: next_seq} = q, unit) do
    stamped =
      if Map.has_key?(unit, :seq) do
        # Re-enqueue (restale): increment restale_count, preserve enqueued_at.
        Map.update(unit, :restale_count, 1, &(&1 + 1))
      else
        # First entry: stamp seq, set restale_count = 0, record enqueued_at.
        unit
        |> Map.put(:seq, next_seq)
        |> Map.put(:restale_count, 0)
        |> Map.put_new(:enqueued_at, System.monotonic_time(:millisecond))
      end

    new_next_seq = if Map.has_key?(unit, :seq), do: next_seq, else: next_seq + 1
    updated = %__MODULE__{q | entries: entries ++ [stamped], next_seq: new_next_seq}
    {updated, stamped}
  end

  @doc """
  Dequeues a batch: all entries tied at the minimum effective_priority.

  Returns `{batch, remaining_queue}` where every unit in `batch` has an
  effective_priority <= every unit in the remaining queue.

  An empty queue returns `{[], queue}`.
  """
  @spec dequeue_batch(t()) :: {[map()], t()}
  def dequeue_batch(%__MODULE__{entries: []} = q), do: {[], q}

  def dequeue_batch(%__MODULE__{entries: entries} = q) do
    min_prio = entries |> Enum.map(&effective_priority/1) |> Enum.min()

    {batch, rest} = Enum.split_with(entries, fn u -> effective_priority(u) == min_prio end)

    {batch, %__MODULE__{q | entries: rest}}
  end

  @doc """
  Computes the effective priority of a unit.

      effective_priority = seq - aging_weight * restale_count

  Lower value = higher urgency. `restale_count` defaults to `0` if absent.
  """
  @spec effective_priority(map()) :: number()
  def effective_priority(%{seq: seq} = unit) do
    restale_count = Map.get(unit, :restale_count, 0)
    seq - @aging_weight * restale_count
  end
end
