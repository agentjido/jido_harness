# Jido v3 contract

This fixture checks the package with consolidated Jido in one dependency graph.
The package has no required core runtime dependency. Run these commands here:

```sh
mix deps.get
mix test
```

The checks use no model or live provider. Core owns `Jido.Action`, `Jido.Signal`,
and `Jido.AI` modules. Do not add the separate legacy packages to this graph.
