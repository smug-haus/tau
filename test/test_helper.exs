# Excluded by default; opt-in with `--include` / `--only`:
#   :smoke       — Burrito binary smoke tests (need zig + xz to build the release)
#   :tui_smoke   — TUI PTY harness (needs tmux + a built binary)
#   :external    — coding-agent adapter tests that spawn real CLIs
#                  (`INTEGRATION=1 mix test --only external`).
#   :integration — slow end-to-end harness tests that boot real subsystems via a
#                  Mix task subprocess (e.g. the P5c-7 dogfood capstone,
#                  `test/tau/factory/dogfood_e2e_test.exs` — AC-12). Opt in with
#                  `mix test --include integration`.

ExUnit.start(exclude: [:smoke, :tui_smoke, :tui_ux, :external, :integration])
