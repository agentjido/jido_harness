[
  plugins: [Spark.Formatter],
  import_deps: [:jido, :jido_action],
  locals_without_parens: [
    harness: 1,
    connection: 1,
    workspace: 1,
    provider: 1,
    root: 1,
    default_workspace: 1,
    defaults: 1,
    allowed_options: 1,
    commands: 1,
    signals: 1
  ],
  inputs: [
    "{mix,.formatter,.credo,.doctor}.exs",
    "{bench,config,lib,test}/**/*.{ex,exs}",
    "guides/recipes/**/*.exs",
    "vendor/erlexec/compiler.exs"
  ],
  line_length: 120
]
