---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Introduce Tau.Settings.FileSystemAdapter behaviour and a safe default impl

## Approach

Define a `Tau.Settings.FileSystemAdapter` behaviour with a single callback
`start_and_subscribe(dirs :: [Path.t()]) :: {:ok, pid()} | {:error, term()}`.
The production implementation (`Tau.Settings.FileSystemAdapter.Default`) calls
`FileSystem.start_link/1` and `FileSystem.subscribe/1` — no try/rescue/catch —
and is the only module that directly imports `FileSystem`. `maybe_start_watcher/1`
calls the adapter via `@fs_adapter.start_and_subscribe(dirs)`. The adapter module
is injected via application config (defaulting to `Default`). Tests inject a
`Tau.Settings.FileSystemAdapter.Stub` that returns controlled values including
`{:error, :test_reason}` without touching `FileSystem` at all.

## Rationale

The deepest complection is not just `catch :exit` vs. pattern matching — it is
that `maybe_start_watcher/1` is coupled to the concrete `FileSystem` library's
error modes. Any refactor of the `try` block (Proposals 1 and 2) leaves
`FileSystem` as a direct dependency of Watcher, making it impossible to test
the degraded-mode path without involving the real `FileSystem` library. Extracting
a behaviour seam decomplects the Watcher's *startup logic* from the *library's
error-surface*. The `catch :exit` disappears because the seam's contract is
`{:ok, pid} | {:error, term()}` — the implementation behind the seam handles
(or doesn't handle) library failures at the implementation level, in isolation.
The Watcher never sees an `:exit` because it never calls across the process
boundary directly.

## Sketch

```elixir
# lib/tau/settings/file_system_adapter.ex
defmodule Tau.Settings.FileSystemAdapter do
  @moduledoc "Seam between Settings.Watcher and the :file_system library."

  @callback start_and_subscribe(dirs :: [Path.t()]) ::
              {:ok, pid()} | {:error, term()}
end

# lib/tau/settings/file_system_adapter/default.ex
defmodule Tau.Settings.FileSystemAdapter.Default do
  @moduledoc "Production impl — delegates to FileSystem directly."
  @behaviour Tau.Settings.FileSystemAdapter

  @impl true
  def start_and_subscribe(dirs) do
    case FileSystem.start_link(dirs: dirs) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        {:ok, pid}

      other ->
        {:error, other}
    end
  end
end

# lib/tau/settings/watcher.ex (changed portion only)
@fs_adapter Application.compile_env(
              :tau,
              [Tau.Settings.Watcher, :fs_adapter],
              Tau.Settings.FileSystemAdapter.Default
            )

defp maybe_start_watcher(dirs) do
  cond do
    not Code.ensure_loaded?(FileSystem) ->
      {:error, :file_system_not_loaded}

    dirs == [] ->
      {:error, :no_dirs}

    true ->
      @fs_adapter.start_and_subscribe(dirs)
  end
end
```

Test stub (in `test/support/`):
```elixir
defmodule Tau.Settings.FileSystemAdapter.Stub do
  @behaviour Tau.Settings.FileSystemAdapter

  @impl true
  def start_and_subscribe(_dirs), do: {:error, :stub_unavailable}
end
```

In `config/test.exs`:
```elixir
config :tau, Tau.Settings.Watcher, fs_adapter: Tau.Settings.FileSystemAdapter.Stub
```

## Tradeoffs

### Strengths

- Eliminates `catch :exit` while simultaneously enabling deterministic tests of
  the degraded-mode path without real `FileSystem` processes.
- The `FileSystemAdapter.Default` impl is the only place that calls
  `FileSystem.start_link/1`; if that library's error surface changes, one
  module changes — not Watcher's init logic.
- OTP NN #2 compliant: extensibility seam is a behaviour, not a string-keyed
  dispatch.
- The acceptance criterion is fully satisfied: no `try/rescue/catch` in Watcher;
  legitimate failures are return-value pattern-matched; degraded-mode telemetry
  is unchanged.
- Supports future expansion (e.g. a `FileSystemAdapter.INotify` for Linux-specific
  optimisation) without touching Watcher.

### Weaknesses

- Scope is wider than the other proposals: introduces 2 new modules and config
  entries vs. 1 file change. This may be considered over-engineering for removing
  a single `catch :exit`.
- `Application.compile_env/3` for adapter injection is evaluated at compile time;
  runtime injection (e.g. in tests that change the adapter mid-run) requires a
  different mechanism (e.g. module attribute + `Application.get_env/3` at call
  time). The sketch above uses compile-time injection, which is simpler but less
  flexible.
- The `Default` impl still calls `FileSystem.start_link/1` directly; an `:exit`
  from that call propagates through `Default.start_and_subscribe/1` up to
  `maybe_start_watcher/1` and then to `init/1` — same as Proposal 1. The
  behaviour seam does not change the crash propagation path; it only makes it
  testable without real `FileSystem`.
- Two extra files to maintain.

### Costs

- ~50 lines added (behaviour, default impl, stub, config entry).
- 2 new files: `lib/tau/settings/file_system_adapter.ex`,
  `lib/tau/settings/file_system_adapter/default.ex`.
- 1 file changed: `lib/tau/settings/watcher.ex`.
- 1 config entry: `config/test.exs`.
- New tests for the degraded path become trivial to write (no PTY or OS-level
  filesystem setup needed).

## Dependencies

- `Application.compile_env/3` available since Elixir 1.10 — satisfied by
  Elixir 1.18.1 in `.tool-versions`.
- No new libraries.

## Confidence

medium — the pattern is idiomatic OTP/Elixir (`Application.compile_env` for
adapter injection is used in `Tau.Settings.Cache` and similar modules). Confidence
would rise with confirmation that `Application.compile_env` is used elsewhere
in the project for adapter injection (not yet verified).

## Prior art / references

- OTP NN #2: "Extensibility seams MUST be behaviours."
- Elixir docs: `Application.compile_env/3` — module-level compile-time injection.
- The pattern of `@adapter Application.compile_env(...)` is idiomatic in Phoenix
  and Ecto for swappable adapters in test vs. production.
