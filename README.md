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
- not currently generating python type hints (e.g. function arguments and return types), but gleam gives us that info so may as well use it
- no concept of a "project", gleam.toml, downloading dependencies
- only compiles one module at a time
- not sure how to account for `/` on two ints.
