# macabre

```sh
gleam run -- some_file.gleam  # compile to python
```

## Development

```sh
gleam test  # Run tests with glacier
```

### TODO

- most operators and expressions aren't implemented yet
- glance doesn't support comments
- glance doesn't fully typecheck (e.g. `2.0 - 1.5` compiles successfully, but should be `2.0 -. 1.5`)
- no concept of a "project", gleam.toml, downloading dependencies
- only compiles one package at a time
- not sure how to account for `/` on two ints.
