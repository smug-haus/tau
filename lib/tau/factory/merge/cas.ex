defmodule Tau.Factory.Merge.Cas do
  @moduledoc """
  The COMMIT critical section as pure data + effects for the Merge Authority.

  Two functions:

    - `assert_all_verdicts_live/3` — re-reads the **latest** verdict status for
      every (unit, half) pair at the merge instant (HR-2, D-300). Returns
      `:all_pass` only if every required half's latest status is `{:ok, :pass}`.
      Returns `{:revoked, unit}` on the first revoked or missing half.

    - `cas_push/3` — runs `git push --force-with-lease=refs/heads/main:<oid>`
      (HR-1, D-301). Returns `:ok` on success or `{:error, :stale_ref}` on a
      lease rejection. Never raises on rejection.

  See `docs/spec/SPEC-FACTORY-MERGE.md` §4 B3/B4, D-300, D-301.
  """

  alias Tau.Factory.Ledger.Writer

  @doc """
  Re-read the latest verdict status for every `(unit, half)` pair in `units ×
  required_halves`.

  Returns `:all_pass` if and only if every query returns `{:ok, :pass}`.
  Returns `{:revoked, unit}` on the first unit whose any required half yields
  `{:ok, :fail}` or `:none`.
  """
  @spec assert_all_verdicts_live(GenServer.server(), [map()], [:critic | :reviewer]) ::
          :all_pass | {:revoked, map()}
  def assert_all_verdicts_live(ledger, units, required_halves) do
    Enum.reduce_while(units, :all_pass, fn unit, :all_pass ->
      case check_unit(ledger, unit, required_halves) do
        :all_pass -> {:cont, :all_pass}
        {:revoked, ^unit} = revoked -> {:halt, revoked}
      end
    end)
  end

  @doc """
  Push `tip` onto `origin/main` using `--force-with-lease` anchored at
  `expected_old_oid`.

  Runs `git push --force-with-lease=refs/heads/main:<expected_old_oid> origin
  <tip>:refs/heads/main` inside `repo_dir`.

  Returns:
    - `:ok` on exit 0.
    - `{:error, :stale_ref}` when the remote rejects the push due to a stale
      lease (output contains "stale", "rejected", or "force-with-lease").
    - `{:error, {:git_error, output}}` for other git failures.
  """
  @spec cas_push(String.t(), String.t(), String.t()) ::
          :ok | {:error, :stale_ref} | {:error, term()}
  def cas_push(repo_dir, tip, expected_old_oid) do
    # Fetch first so the local remote-tracking ref is current. Without this,
    # --force-with-lease compares against a stale local tracking ref and
    # would not detect a concurrent push that advanced origin/main (HR-1, D-301).
    System.cmd("git", ["fetch", "origin"], cd: repo_dir, stderr_to_stdout: true)

    lease_arg = "refs/heads/main:#{expected_old_oid}"
    refspec = "#{tip}:refs/heads/main"

    {output, exit_code} =
      System.cmd(
        "git",
        ["push", "--force-with-lease=#{lease_arg}", "origin", refspec],
        cd: repo_dir,
        stderr_to_stdout: true
      )

    cond do
      exit_code == 0 ->
        :ok

      stale_ref_output?(output) ->
        {:error, :stale_ref}

      true ->
        {:error, {:git_error, output}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp check_unit(ledger, unit, required_halves) do
    Enum.reduce_while(required_halves, :all_pass, fn half, :all_pass ->
      coord = %{hash: unit.hash, run: unit.run, half: half}

      case Writer.latest_verdict_status(ledger, coord) do
        {:ok, :pass} -> {:cont, :all_pass}
        {:ok, :fail} -> {:halt, {:revoked, unit}}
        :none -> {:halt, {:revoked, unit}}
      end
    end)
  end

  defp stale_ref_output?(output) do
    lower = String.downcase(output)

    String.contains?(lower, "stale info") or
      String.contains?(lower, "stale") or
      String.contains?(lower, "rejected") or
      String.contains?(lower, "force-with-lease")
  end
end
