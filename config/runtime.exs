import Config

# runtime.exs is evaluated on every release boot AND on every `mix` invocation
# in :prod, but NOT during compilation. Use it to read env vars and resolve
# user-overridable settings.

if config_env() == :prod do
  data_dir =
    System.get_env("TAU_DATA_DIR") ||
      Path.join(System.user_home!() || ".", ".tau")

  config :tau, data_dir: data_dir

  if api_key = System.get_env("ANTHROPIC_API_KEY") do
    config :tau, Tau.Providers.Anthropic, api_key: api_key
  end

  if api_key = System.get_env("OPENAI_API_KEY") do
    config :tau, Tau.Providers.OpenAI, api_key: api_key
  end

  if api_key = System.get_env("GOOGLE_API_KEY") || System.get_env("GEMINI_API_KEY") do
    config :tau, Tau.Providers.Gemini, api_key: api_key
  end

  # SPEC-OTEL-REPORTER (#35 / AC-1): OTel reporter config from env.
  # The reporter process is wired in PR2; this block reads config so
  # the schema is present from PR1 onward.
  #
  # TAU_OTEL_ENABLED=true activates the reporter.
  # TAU_OTEL_ENDPOINT sets the OTLP endpoint (default http://localhost:4317).
  # TAU_OTEL_SAMPLING sets the sampling ratio [0.0, 1.0] (default 1.0).
  if System.get_env("TAU_OTEL_ENABLED") in ~w(1 true yes) do
    otel_config =
      [
        enabled: true,
        endpoint: System.get_env("TAU_OTEL_ENDPOINT") || "http://localhost:4317",
        sampling_ratio:
          case Float.parse(System.get_env("TAU_OTEL_SAMPLING") || "1.0") do
            {ratio, _} -> ratio
            :error -> 1.0
          end
      ]

    config :tau, :otel, otel_config
  end
end
