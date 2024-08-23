# Macabre

**macabre** : (adj) _tending to produce horror in a beholder_

Seriously, Just back away slowly. I'm just playing around.

Are you still here? Don't you know there's a monster at the end of this book?

## OMG, What have you done?

Nothing, yet. It only "barely" works if we carefully redefine "barely" to "doesn't".

This is an ultra experimental compiler written in Gleam to compile Gleam source code (using
the [glance](https://hexdocs.pm/glance/) package) to Python.

## Why are you doing this?

I have no idea. It's fun and educational. (I'm on a roll with this redefining words thing.)

## Usage

```sh
gleam run -- some_very_simple_file.gleam  # compile to python
```

## Development

Run tests with gleeunit:

```sh
gleam test
```

Run tests in watch mode:

```sh
fd .gleam | entr gleam test
```

## Contributing

Are you insane?

Sweet, me too.

PRs are welcome.

### Some of the things I know are missing

- no destructuring/pattern matching in let
- no let assert
- no case expressions
- label aliases aren't supported yet (ie `fn foo(bar bas: Str)`)
- const definitions aren't supported yet (module.constants)
- type aliases aren't supported yet (module.type_aliases)
- use statements aren't supported yet
- bitstrings aren't supported yet (map to bytes)
- No Result custom types yet
- Shadowed variable names behave differently if used in closures
  - made more complicated by the fact that the python code will likely have more
    closures
  - solution might be to keep track of used names and use unique ones when they
    are shadowed
- List custom type is missing `match_args`, other helpers
- glance doesn't support comments
- glance doesn't typecheck (e.g. `2.0 - 1.5` compiles successfully, but should
  be `2.0 -. 1.5`)
- Not doing anything to avoid collision between gleam identifiers with python keywords
- not currently generating python type hints (e.g. function arguments and
  return types), but gleam gives us that info so may as well use it
- haven't really tested with nesting of expressions
- need to print out nice errors when glance fails to parse
- no concept of a "project", gleam.toml, downloading dependencies
- only compiles one module at a time
- copies the prelude module blindly into the directory that contains that one module
- eliminate all todos in source code
- No standard library
- generate **main** if a module has a main function
- calling functions or constructors with out-of-order positional args doesn't
  work in python
  - e.g. `Foo(mystr: String, point: #(Int, Int))` can be called with `Foo(#(1,
1), mystr: "Foo")` in gleam
  - javascript seems to solve this by automatically reordering the arguments to
    match the input type
- custom types with unlabelled fields are not working
  - Given that labelled and unlabelled fields can be mixed on one class, I have
    a feeling we have to ditch dataclasses. Probably a custom class with slots, a
    dict of names to indices, and a custom **match_args** that can handle
    tuple-like _or_ record-like syntax?
- I notice that the javascript doesn't generate the wrapping class for custom
  variants. Can we get away with not having them?
- Related: if you have a multi-variant type where the first constructor shadows
  the type's name, it breaks
- maybe call ruff or black on the files after they are output, if they are installed.
