# Macabre

**macabre** : (adj) _tending to produce horror in a beholder_

This is an ultra experimental compiler written in Gleam to compile Gleam source
code (using the [glance](https://hexdocs.pm/glance/) package) to Python.

It covers a pretty decent swath of Gleam syntax, and I made a point of
prioritizing the hardest syntax. There is a big pile of TODOs at the end of
this file if you want to contribute.

My current vision is to have fun while making this a self-hosted compiler. Once
it can compile itself to Python (bonus points if it runs on a variation of
gleam_otp that uses Python's upcoming new experimental multi-threaded support),
well at that point, I'll have to come up with a new vision. Maybe something to
do with supporting other compilation targets, such as Gleam's native Erlang
and Javascript environments.

Probability of achieving this vision: pretty low. This is a for-fun free
time project for me. I'm currently on sabbatical so I have time for odd
little projects like this.

## Usage

The complier runs on gleam erlang successfully. I think it might work with
Javascript as I don't think I'm using any erlang-specific libraries yet. It
can't compile itself to python yet, but I'm hoping to get there.

To run it, pass it a properly structured macabre folder as the only argument:

```sh
gleam run -- some_package_folder
```

The package folder should have a structure similar to a normal Gleam project:

```
folder
├── gleam.toml
├── build
│   └── <generated stuff>
└─ src
    ├── <repo_name>.gleam
    ├── some_folder
    │   ├── something.gleam
    │   └── bindings.py
    ├── some_file.gleam
    └── some_bindings.py
```

The `gleam.toml` only supports two keys, name and dependencies:

```toml
name = "example"

[dependencies]
macabre_stdlib = "git@github.com:dusty-phillips/macabre_stdlib.git"
```

Note that dependencies are currently _not_ hex packages like a normal gleam
project. Rather, they are git repositories. This is mostly because I didn't
feel comfortable cluttering hex with silly dependencies for my silly project.

The compiler expects git to be installed, and will clone any git repos that are
listed.

> [!WARNING} It currently downloads everything from scratch every time you
> invoke it, so don't try this on a metered connection!

Macabre copies the `src/` folder of each package into the build directory and
then builds all dependencies from scratch (every single time). Your source
files are also copied into this folder.

Your main module will always be `<repo_name>.gleam` where `<repo_name>` is whatever
you put in the `name` in `gleam.toml`.

Your files are compiled to `build/dev/python`. If your `<repo_name>.gleam` has
a `main` function in it, then the compiler will generate a
`build/dev/python/__main__.py` to call that function.

Use this command to invoke it:

```shell
python build/dev/python
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

PRs are welcome.

The main entry point is `macabre.gleam`, which handles all file loading and
other side effects.

The package depends on the [glance](https://github.com/lpil/glance) AST parser,
and [glimpse](https://github.com/dusty-phillips/glimpse),
a package I wrote to wrap glance to support multiple inter-dependent modules.
(Eventually I want it to also be a glance typechecker)

The compiler is pure gleam. Most of the work happens in
`transformer.gleam` and `generator.gleam`. The former converts the Gleam AST to
a Python AST, the latter generates python code. There are tons of helper
functions in various other files.

The Python AST is in `python.gleam`. This doesn't model all of python; just the
subset that is needed to map Gleam expressions to.

Some tasks below are marked easy if you want to get started.

### Outstanding tasks

### High Pri

- Functions as type fields are not supported yet
  - e.g pub type Foo {Foo(x: () -> String)}
  - debatable whether to make them a `def` right on the class or have the def be defined somewhere and just attach it like other fields
- IN case statements, the following patterns are not supported:
  - Concatenate patterns
  - Bitstring patterns (bytes)
  - The problem with both is python match has no way to match on "parts" of bytes or strings. Possible solutions:
    - convert the entity to a python list and match on that
    - construct a potentially massive match guard ('case ... if') to compare elements.
- Destructuring in assignments is not supported yet
  - (EASY) tuple destructuring can map straight to python destructuring
  - other structures will maybe need a match statement?
- type aliases aren't supported yet (module.type_aliases)
- (EASY) internal/errors.format_token needs help
- glance doesn't have (much of) a typechecker
  - Might be able to extract one from [gig](https://github.com/schurhammer/gig)
  - This work is expected to happen in [glimpse](https://github.com/dusty-phillips/glimpse?tab=readme-ov-file)
    so it can be reused by other compiler projects
- Code is very not commented
- (EASY) Should be putting public types, functions, and constants in `__all__`

### Low Pri

- (EASY) Turn this list into github issues
- imports with attributes are not handled yet
- type imports are not implemented yet
- not currently generating python type hints (e.g. function arguments and
  return types), but gleam gives us that info so may as well use it
  - No Result custom type yet (I thought this needed to be in the prelude, but I don't see any result-specific syntax anywhere)
- Unlabelled fields in custom types are not generated yet
  - Given that labelled and unlabelled fields can be mixed on one class, I have
    a feeling we have to ditch dataclasses. Probably a custom class with slots, a
    dict of names to indices, and a custom **match_args** that can handle
    tuple-like _or_ record-like syntax?
- Labelled parameters in function calls are not transformed (ie `fn foo(bar baz: Str)`)
- Codepoints in bistrings are not supported yet
- non-byte-aligned bitstrings are not supported yet
- Fields that are "HoleType" are not supported and I don't even know what that means
- no let assert
- macabre_stdlib only has `io.println`
- Not doing anything to avoid collision between gleam identifiers with python keywords
  - Especially: shadowed variable names behave differently if used in closures
- glance itself doesn't support comments, so these are stripped out of the compiled code
- the standard gleam LSP chokes on the fact that I don't have dependencies in hex
- calling functions or constructors with out-of-order positional args doesn't
  work in python
  - e.g. `Foo(mystr: String, point: #(Int, Int))` can be called with `Foo(#(1,
1), mystr: "Foo")` in gleam
  - javascript seems to solve this by automatically reordering the arguments to
    match the input type
    for all the types in a single class.
- (EASY) maybe call ruff or black on the files after they are output, if they are installed. (shellout is already available)
- See if there are ways to leverage the [gleam_package_interface](https://github.com/gleam-lang/package-interface)
