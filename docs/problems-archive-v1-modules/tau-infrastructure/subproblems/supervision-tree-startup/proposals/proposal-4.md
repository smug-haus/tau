---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Redesign CLI dispatch as a dedicated OTP application with its own supervisor

## Approach

Split the CLI execution lifecycle out of `Tau.Application` entirely and into a
new OTP application `tau_cli` (a new `mix.exs` library application entry in the
`:included_applications` list, or more practically a new `Tau.CLI.App` module
started via `Application.start/2` after the main supervision tree is healthy).
`Tau.CLI.App` owns a minimal one-child supervisor whose sole child is a
`Tau.CLI.Runner` GenServer (`:temporary` restart, `max_restarts: 0`). `Runner`
spawns `Tau.CLI.main/1` in a linked process with `trap_exit: true`, captures the
exit, and calls `System.halt/1`. `Tau.Application` becomes purely a platform
supervisor with no CLI-dispatch concern; it always includes `Tau.OtelReporter`
unconditionally and uses `max_restarts: 10, max_seconds: 60`.

## Rationale

The root cause of the complecting is that `Tau.Application` currently owns two
orthogonal concerns: (1) bootstrapping the platform supervision tree and
(2) dispatching and observing the CLI entry point. An OTP-idiomatic separation
places the platform in one application and the CLI lifecycle in a second
application that depends on the first. This is the pattern Erlang/OTP uses for
`erts` + `kernel` + `stdlib` layering: each layer starts cleanly before the
next. In this design `Tau.Application.start/2` never blocks or dispatches; the
CLI app starts only after the platform is healthy, and the platform's supervisor
cannot be destabilised by a CLI crash (different application, different
supervisor). The OTel single-gate is achieved by removing `otel_reporter_spec/0`
and relying on `init/1`.

## Sketch

```elixir
# lib/tau/cli/app.ex  (new file)
defmodule Tau.CLI.App do
  @moduledoc """
  OTP application for the CLI lifecycle. Started after Tau.Application
  when a CLI argv is detected. Supervises a single :temporary Tau.CLI.Runner
  child; Runner traps its linked CLI process and calls System.halt/1 on exit.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [Tau.CLI.Runner]
    opts = [strategy: :one_for_one, name: Tau.CLI.Supervisor, max_restarts: 0]
    Supervisor.start_link(children, opts)
  end
end

# lib/tau/cli/runner.ex  (new file)
defmodule Tau.CLI.Runner do
  @moduledoc """
  Runs Tau.CLI.main/1 in a linked process. Traps the exit and calls
  System.halt/1 with the exit code. Returns :ignore when not in CLI mode.
  """
  use GenServer, restart: :temporary

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init([]) do
    case Tau.Application.cli_argv() do
      :no_cli ->
        :ignore

      {:dispatch, argv} ->
        Process.flag(:trap_exit, true)
        _pid = spawn_link(fn ->
          code =
            case Tau.CLI.main(argv) do
              n when is_integer(n) -> n
              _ -> 0
            end

          exit({:tau_exit, code})
        end)

        {:ok, %{}}
    end
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, {:tau_exit, code}}, state) do
    System.halt(code)
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, :normal}, state) do
    System.halt(0)
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    System.halt(1)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
```

```elixir
# mix.exs — add :tau_cli to :included_applications or start it explicitly.
# In practice, the simplest implementation avoids a second mix.exs:
# Tau.Application.start/2 calls Application.start(:tau_cli) after
# Supervisor.start_link succeeds, OR Tau.CLI.App is started as the
# last entry in the :applications list in mix.exs so OTP starts it
# after :tau automatically.

# lib/tau/application.ex changes:
# 1. Replace otel_reporter_spec() call with Tau.OtelReporter (unconditional)
# 2. Remove maybe_dispatch_cli/0 and its call site
# 3. Set max_restarts: 10, max_seconds: 60
# 4. Delete otel_reporter_spec/0
```

The practical trade-off is whether `tau_cli` is a true OTP application
(separate `mix.exs`) or a module-level `Application.start` call inside
`Tau.Application.start/2`. Either is valid; the second option avoids adding a
new `:applications` entry and is the minimal path.

## Tradeoffs

### Strengths

- Strongest separation of concerns: `Tau.Application` is purely a platform
  supervisor; the CLI lifecycle has its own supervisor and its own restart
  intensity (none — `:temporary`, `max_restarts: 0`).
- A crash in `Tau.CLI.Runner` cannot cascade into the platform supervisor — the
  two supervisors are entirely independent.
- The `trap_exit` + `handle_info` pattern is contained in a module dedicated to
  this purpose; no footgun leakage into general-purpose GenServers.
- Closes all three acceptance criterion items (a)(b)(c).
- The `restart: :temporary` + `max_restarts: 0` on the CLI supervisor explicitly
  states "this runs once, never restarts" — the right semantic for a binary CLI
  runner.

### Weaknesses

- Highest conceptual overhead: a second application (or a second supervision
  tree call) for what is currently a 15-line function. Reviewers unfamiliar with
  OTP application layering will view this as over-engineering.
- If implemented as a true separate OTP application, requires changes to
  `mix.exs` and potentially to the release configuration — non-trivial impact
  for what the problem statement classifies as a minor/major defect pair.
- The `Tau.Application.cli_argv/0` function is consumed by `Tau.CLI.Runner.init/1`
  across application boundaries — if `Tau.Application` is ever renamed or split,
  this reference breaks.
- `Application.start(:tau_cli)` called from within `Tau.Application.start/2`
  is an unusual pattern (one application starting another synchronously during
  its own start); OTP allows it but it is not common practice and can confuse
  release tooling.
- Most complex migration of the four proposals.

### Costs

- Two new files (`lib/tau/cli/app.ex`, `lib/tau/cli/runner.ex`, ~60 lines total).
- `lib/tau/application.ex`: ~10 lines removed (two functions, one call site, one
  child list entry changed).
- If a true second OTP application: changes to `mix.exs` `:extra_applications`
  or `:included_applications`, and possibly to `rel/config.exs` or Burrito config.
- Test suite: any tests that assert on `Tau.Application`'s CLI dispatch path
  must be updated; new unit tests needed for `Tau.CLI.Runner`.

## Dependencies

- `Tau.Application.cli_argv/0` must remain accessible from `Tau.CLI.Runner`
  (currently `@doc false` public — acceptable).
- `Tau.OtelReporter.init/1` must honour `:ignore` (confirmed).
- `Tau.CLI.App` / `Tau.CLI.Runner` must start after the full `Tau` supervision
  tree is up; ordering must be guaranteed (either via `:included_applications`
  or explicit `Application.start` sequencing).

## Confidence

Low-medium. The OTP application layering pattern is sound in principle, but the
implementation details (`:included_applications` vs explicit `Application.start`
vs truly separate mix project) have non-trivial correctness constraints. The
simple module-level approach (start `Tau.CLI.App` explicitly inside
`Tau.Application.start/2`) is the most practical but least idiomatic OTP path.
Confidence rises to medium after prototyping the startup sequence and verifying
Burrito build output remains intact.

## Prior art / references

- OTP `:included_applications` — OTP Design Principles §"Included Applications";
  allows one application to start child applications in a defined order.
- `:temporary` restart strategy for one-shot workers — `Supervisor` docs
  §"Child specification" `restart:` option.
- Elixir `Application.start/2` explicit sequencing — used in Phoenix when
  `Endpoint` must start after `Ecto.Repo` is up.
- Erlang `escript` + supervision tree — common pattern for CLI tools that need
  full OTP but with a clean process separation between the platform and the
  user-facing entry point.
