import Config

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:module]

import_config "#{config_env()}.exs"
