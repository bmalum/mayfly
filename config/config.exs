import Config

# Mayfly itself needs no configuration. This file only quiets the logger while
# running Mayfly's own test suite.
if config_env() == :test do
  config :logger, level: :warning
end
