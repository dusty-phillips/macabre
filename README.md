# Macabre

**macabre** : (adj) _tending to produce horror in a beholder_

Seriously, Just back away slowly. I'm just playing around.

Are you still here? Don't you know there's a monster at the end of this book?

## What have you done?

Nothing, yet. It only "barely" works if we carefully redefine "barely" to "doesn't".

This is an ultra experimental compiler written in Gleam to compile Gleam source code (using
the [glance](https://hexdocs.pm/glance/) package) to Python.

## Why are you doing this?

I have no idea. It's fun and educational. (I'm on a role with this redefining words thing.)

## Usage

```sh
gleam run -- some_very_simple_file.gleam  # compile to python
```

## Development

```sh
gleam test  # Run tests with glacier
```

## Contributing

Are you insane? Sweet, me too. PRs are welcome.

### TODO

- flesh out this list
- most expressions aren't implemented yet
- need to print out nice errors when glance fails to parse
- No List or Result custom types yet
- glance doesn't support comments
- glance doesn't fully typecheck (e.g. `2.0 - 1.5` compiles successfully, but should be `2.0 -. 1.5`)
- not currently generating python type hints (e.g. function arguments and return types), but gleam gives us that info so may as well use it
- no concept of a "project", gleam.toml, downloading dependencies
- only compiles one module at a time
- eliminate all todos in source code
