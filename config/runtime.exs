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
end
