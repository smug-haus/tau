# Excluded by default; opt-in with `--include` / `--only`:
#   :smoke       — Burrito binary smoke tests (need zig + xz to build the release)
#   :tui_smoke   — TUI PTY harness (needs tmux + a built binary)
#   :external    — coding-agent adapter tests that spawn real CLIs
#                  (`INTEGRATION=1 mix test --only external`).
#   :integration — slow end-to-end harness tests that boot real subsystems via a
#                  Mix task subprocess (e.g. the P5c-7 dogfood capstone,
#                  `test/tau/factory/dogfood_e2e_test.exs` — AC-12). Opt in with
#                  `mix test --include integration`.

# Start a global Tau.Factory.WorkerRegistry process so that tests that reference
# @worker_registry Tau.Factory.WorkerRegistry can use Registry.lookup/2 on it.
# Workers in isolation tests register in per-test dynamic registries; this global
# registry is a no-op fallback that returns [] for any lookup (D-365 isolation test).
{:ok, _} = Tau.Factory.WorkerRegistry.start_link(name: Tau.Factory.WorkerRegistry)

ExUnit.start(exclude: [:smoke, :tui_smoke, :tui_ux, :external, :integration])
