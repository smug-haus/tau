import Config

# Tests must not write to the user's real ~/.tau directory.
# Tests that need persistence should set this via `Application.put_env/3` per case.
config :tau,
  data_dir: System.tmp_dir!() |> Path.join("tau-test-#{System.system_time(:millisecond)}")

# Force the replay (test-only) provider as default; real providers are tested via Bypass.
config :tau, default_provider: Tau.Providers.Replay

config :logger, level: :warning

# Use a no-op stub embedder by default in tests so write/1 does not attempt
# real HTTP calls. Tests that need to verify the pipeline wire use
# Tau.Memory.StubEmbedder or set their own implementation via put_env.
config :tau, embedder: Tau.Memory.StubEmbedder
