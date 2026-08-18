import compiler/generator
import compiler/internal/comments
import compiler/internal/transformer as internal
import compiler/package
import compiler/project
import compiler/transformer
import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string
import glimpse

pub fn compile_module(glance_module: glance.Module) -> String {
  compile_module_with_signatures(glance_module, dict.new())
}

pub fn compile_module_with_signatures(
  glance_module: glance.Module,
  function_signatures: internal.FunctionSignatures,
) -> String {
  compile_module_with_arities(
    glance_module,
    function_signatures,
    module_arities(glance_module),
  )
}

pub fn compile_module_with_arities(
  glance_module: glance.Module,
  function_signatures: internal.FunctionSignatures,
  constructor_arities: dict.Dict(String, List(String)),
) -> String {
  compile_module_with_externals(
    glance_module,
    function_signatures,
    constructor_arities,
    [],
  )
}

pub fn compile_module_with_externals(
  glance_module: glance.Module,
  function_signatures: internal.FunctionSignatures,
  constructor_arities: dict.Dict(String, List(String)),
  external_functions: List(String),
) -> String {
  compile_module_with_external_qualified(
    glance_module,
    function_signatures,
    constructor_arities,
    external_functions,
    [],
  )
}

pub fn compile_module_with_external_qualified(
  glance_module: glance.Module,
  function_signatures: internal.FunctionSignatures,
  constructor_arities: dict.Dict(String, List(String)),
  external_functions: List(String),
  external_qualified: List(String),
) -> String {
  compile_module_with_comments(
    glance_module,
    function_signatures,
    constructor_arities,
    external_functions,
    external_qualified,
    [],
  )
}

pub fn compile_module_with_comments(
  glance_module: glance.Module,
  function_signatures: internal.FunctionSignatures,
  constructor_arities: dict.Dict(String, List(String)),
  external_functions: List(String),
  external_qualified: List(String),
  comments: List(comments.Comment),
) -> String {
  compile_module_with_metadata(
    glance_module,
    function_signatures,
    constructor_arities,
    external_functions,
    external_qualified,
    comments,
    "",
    "",
    "",
    set.new(),
  )
}

pub fn compile_module_with_submodules(
  glance_module: glance.Module,
  submodule_names: set.Set(String),
) -> String {
  compile_module_with_metadata(
    glance_module,
    dict.new(),
    module_arities(glance_module),
    [],
    [],
    [],
    "",
    "",
    "",
    submodule_names,
  )
}

pub fn compile_module_with_metadata(
  glance_module: glance.Module,
  function_signatures: internal.FunctionSignatures,
  constructor_arities: dict.Dict(String, List(String)),
  external_functions: List(String),
  external_qualified: List(String),
  comments: List(comments.Comment),
  module_name: String,
  file_path: String,
  module_source: String,
  submodule_names: set.Set(String),
) -> String {
  glance_module
  |> transformer.transform_module_with_metadata(
    option.Some(function_signatures),
    option.Some(constructor_arities),
    external_functions,
    external_qualified,
    comments,
    module_name,
    file_path,
    module_source,
    submodule_names,
  )
  |> generator.generate(constructor_arities)
}

pub fn compile_package(
  package: package.GleamPackage,
) -> package.CompiledPackage {
  let test_modules = set.from_list(project.test_module_names(package.project))
  let dev_modules = set.from_list(project.dev_module_names(package.project))
  package.CompiledPackage(
    project: package.project,
    has_main: dict.get(package.package.modules, package.project.name)
      |> result.try(fn(mod) { mod.module.functions |> has_main_function })
      |> result.is_ok,
    modules: package.package.modules
      |> dict.map_values(fn(module_name, value) {
        // The package-wide arity map keys constructors by their qualified
        // `<last_segment>.<name>` form; bare names can collide across modules
        // (e.g. glance's `LabelledField` and python's own `LabelledField`), so
        // the bare keys for the module being compiled come from its own
        // definitions, merged on top to win deterministically.
        let constructor_arities =
          dict.fold(
            module_arities(value.module),
            package_arities(package.package.modules)
              |> dict.fold(
                package_bare_arities(package.package.modules),
                fn(acc, name, field_names) {
                  dict.insert(acc, name, field_names)
                },
              ),
            fn(acc, name, field_names) { dict.insert(acc, name, field_names) },
          )
        let file_path = case set.contains(test_modules, module_name) {
          True -> "test/" <> module_name <> ".gleam"
          False ->
            case set.contains(dev_modules, module_name) {
              True -> "dev/" <> module_name <> ".gleam"
              False -> "src/" <> module_name <> ".gleam"
            }
        }
        let module_source =
          package.module_sources
          |> dict.get(module_name)
          |> result.unwrap("")
        compile_module_with_metadata(
          value.module,
          function_signatures(package.package.modules, module_name),
          constructor_arities,
          module_external_names_with_unqualified(
            value.module,
            package.package.modules,
          ),
          package_externals(package.package.modules),
          package.comments
            |> dict.get(module_name)
            |> result.unwrap([]),
          module_name,
          file_path,
          module_source,
          sibling_submodule_names(package.package.modules, module_name),
        )
      }),
    external_import_files: package.external_import_files,
    main_modules: package.package.modules
      |> dict.filter(fn(_name, module) {
        module.module.functions |> has_main_function |> result.is_ok
      })
      |> dict.keys
      |> set.from_list,
  )
}

// The first path segment of every submodule of this module (e.g. for `bitty`,
// the `bits`, `bytes`, `num`, `string` of `bitty/bits`, `bitty/bytes`, ...).
// Importing `bitty.string` sets the `string` attribute on the `bitty` package,
// so an import binding named `string` in `bitty.gleam` must be renamed to
// avoid being clobbered (e.g. `from gleam import string`).
fn sibling_submodule_names(
  modules: dict.Dict(String, glimpse.Module),
  module_name: String,
) -> set.Set(String) {
  let prefix = module_name <> "/"
  modules
  |> dict.keys
  |> list.filter(fn(name) { string.starts_with(name, prefix) })
  |> list.filter_map(fn(name) {
    name
    |> string.remove_prefix(prefix)
    |> string.split("/")
    |> list.first
  })
  |> set.from_list
}

// Maps constructor names to their field names, in declaration order. Keys
// are the module-qualified form `<last_segment>.<name>` (matching how imports
// default their alias to the module's final segment). Bare names are handled
// per-module by the caller (compile_package merges the module's own bare
// keys on top, since bare names can collide across modules). Used to decide
// whether a capitalized reference is a nullary value (`File()`) or a
// constructor used as a function value (`error.LoadError`, bare), and to
// reorder mixed positional/labelled constructor arguments to match the
// dataclass field order.
fn module_arities(
  glance_module: glance.Module,
) -> dict.Dict(String, List(String)) {
  list.fold(glance_module.custom_types, dict.new(), fn(acc, custom_type) {
    case custom_type {
      glance.Definition(_, glance.CustomType(_, _, _, _, _, variants)) ->
        list.fold(variants, acc, fn(acc, variant) {
          case variant {
            glance.Variant(name, fields, _) ->
              dict.insert(acc, name, variant_field_names(fields))
          }
        })
    }
  })
}

// The generated dataclass field names: labelled fields keep their label,
// unlabelled fields get `_0`, `_1`, ... in the order they appear.
fn variant_field_names(fields: List(glance.VariantField)) -> List(String) {
  let #(_, names) =
    list.fold(fields, #(0, []), fn(state, field) {
      let #(index, acc) = state
      case field {
        glance.LabelledVariantField(_, label) -> #(
          index,
          list.append(acc, [label]),
        )
        glance.UnlabelledVariantField(_) -> #(
          index + 1,
          list.append(acc, ["_" <> int.to_string(index)]),
        )
      }
    })
  names
}

fn package_arities(
  modules: dict.Dict(String, glimpse.Module),
) -> dict.Dict(String, List(String)) {
  let entries =
    modules
    |> dict.fold([], fn(acc, module_name, module) {
      let prefix =
        module_name
        |> string.split("/")
        |> list.last
        |> result.unwrap(module_name)
      module_arities(module.module)
      |> dict.fold(acc, fn(acc, name, field_names) {
        [#(prefix <> "." <> name, field_names), ..acc]
      })
    })
  entries
  |> list.reverse
  |> dict.from_list
  |> add_import_alias_arities(modules)
}

// Bare constructor names across the whole package, e.g. `LocaleBaseName` when
// `import arc/vm/value.{LocaleBaseName, ..}` brings a nullary variant into the
// module without qualifying it. The module being compiled contributes its own
// definitions on top of these so its keys win deterministically (bare names
// can collide across modules).
fn package_bare_arities(
  modules: dict.Dict(String, glimpse.Module),
) -> dict.Dict(String, List(String)) {
  let entries =
    modules
    |> dict.fold([], fn(acc, _module_name, module) {
      module_arities(module.module)
      |> dict.fold(acc, fn(acc, name, field_names) {
        [#(name, field_names), ..acc]
      })
    })
  entries |> list.reverse |> dict.from_list
}

// References to constructors of an aliased import (e.g.
// `import glexer/token as t`, then `t.LeftParen`) are keyed by the alias, so
// the arity map must also carry `<alias>.<name>` keys.
fn add_import_alias_arities(
  acc: dict.Dict(String, List(String)),
  modules: dict.Dict(String, glimpse.Module),
) -> dict.Dict(String, List(String)) {
  let new_entries =
    modules
    |> dict.fold([], fn(entries, _module_name, module) {
      list.fold(module.module.imports, entries, fn(entries, definition) {
        case definition {
          glance.Definition(_, glance.Import(_, module_path, alias, _, _)) ->
            case dict.get(modules, module_path) {
              Error(_) -> entries
              Ok(imported_module) -> {
                let binding = import_binding_name(module_path, alias)
                module_arities(imported_module.module)
                |> dict.fold(entries, fn(entries, name, field_names) {
                  [#(binding <> "." <> name, field_names), ..entries]
                })
              }
            }
        }
      })
    })
  dict.from_list(list.append(dict.to_list(acc), list.reverse(new_entries)))
}

fn import_binding_name(
  module_path: String,
  alias: option.Option(glance.AssignmentName),
) -> String {
  case alias {
    option.Some(assignment) ->
      case assignment {
        glance.Named(name) -> name
        glance.Discarded(name) -> name
      }
    option.None ->
      module_path
      |> string.split("/")
      |> list.last
      |> result.unwrap(module_path)
  }
}

fn assignment_name(name: glance.AssignmentName) -> String {
  case name {
    glance.Named(string) -> string
    glance.Discarded(string) -> string
  }
}

// Builds a map from function name to its parameter labels, used to resolve the
// callback of a desugared `use` statement to its parameter name. Cross-module
// calls are keyed by `last_module_segment.function` (matching how imports
// default their alias to the module's final segment), and the current module's
// own functions are additionally keyed by bare function name.
fn function_signatures(
  modules: dict.Dict(String, glimpse.Module),
  current_module_name: String,
) -> internal.FunctionSignatures {
  let entries =
    modules
    |> dict.fold([], fn(acc, module_name, module) {
      let prefix =
        module_name
        |> string.split("/")
        |> list.last
        |> result.unwrap(module_name)
      let qualified_entries =
        module.module.functions
        |> list.map(fn(function) {
          #(
            prefix <> "." <> function.definition.name,
            function.definition.parameters
              |> list.map(fn(parameter) {
                #(parameter.label, assignment_name(parameter.name))
              }),
          )
        })
        |> list.append(
          module.module.constants
          |> list.map(fn(constant) {
            // A constant is a nullary value, so it has no parameter names; the
            // key just marks the name as a module member so module-qualified
            // references (e.g. `decode.string`) resolve to the module.
            #(prefix <> "." <> constant.definition.name, [])
          }),
        )
      let local_entries = case module_name == current_module_name {
        True ->
          module.module.functions
          |> list.map(fn(function) {
            #(
              function.definition.name,
              function.definition.parameters
                |> list.map(fn(parameter) {
                  #(parameter.label, assignment_name(parameter.name))
                }),
            )
          })
          |> list.append(
            module.module.constants
            |> list.map(fn(constant) { #(constant.definition.name, []) }),
          )
        False -> []
      }
      list.append(qualified_entries, local_entries)
      |> list.fold(acc, fn(acc, entry) { [entry, ..acc] })
    })
  entries
  |> list.reverse
  |> dict.from_list
  |> add_import_alias_signatures(modules)
  |> add_unqualified_import_signatures(modules, current_module_name)
}

// Functions brought in by unqualified imports (`import simplifile.{write}`)
// are called by their bare name, so the signature map must also carry the bare
// name as a key. Aliased imports (`import simplifile.{write: w}`) bind the
// alias instead.
fn add_unqualified_import_signatures(
  acc: internal.FunctionSignatures,
  modules: dict.Dict(String, glimpse.Module),
  current_module_name: String,
) -> internal.FunctionSignatures {
  let new_entries = case dict.get(modules, current_module_name) {
    Error(_) -> []
    Ok(current_module) ->
      current_module.module.imports
      |> list.fold([], fn(entries, definition) {
        case definition {
          glance.Definition(
            _,
            glance.Import(_, module_path, _, _, unqualified_values),
          ) ->
            case dict.get(modules, module_path) {
              Error(_) -> entries
              Ok(imported_module) -> {
                let imported_functions = imported_module.module.functions
                list.fold(unqualified_values, entries, fn(entries, unqualified) {
                  case unqualified {
                    glance.UnqualifiedImport(name, alias) -> {
                      let binding = case alias {
                        option.Some(alias) -> alias
                        option.None -> name
                      }
                      case
                        list.find(imported_functions, fn(function) {
                          function.definition.name == name
                        })
                      {
                        Ok(function) -> [
                          #(
                            binding,
                            function.definition.parameters
                              |> list.map(fn(parameter) {
                                #(
                                  parameter.label,
                                  assignment_name(parameter.name),
                                )
                              }),
                          ),
                          ..entries
                        ]
                        Error(_) -> entries
                      }
                    }
                  }
                })
              }
            }
        }
      })
  }
  dict.from_list(list.append(dict.to_list(acc), list.reverse(new_entries)))
}

// `use` callbacks resolve against the aliased module name (e.g.
// `use <- t.try_fold(...)` for `import gleam/list as t`), so the signature
// map must also carry `<alias>.<name>` keys.
fn add_import_alias_signatures(
  acc: internal.FunctionSignatures,
  modules: dict.Dict(String, glimpse.Module),
) -> internal.FunctionSignatures {
  let new_entries =
    modules
    |> dict.fold([], fn(entries, _module_name, module) {
      list.fold(module.module.imports, entries, fn(entries, definition) {
        case definition {
          glance.Definition(_, glance.Import(_, module_path, alias, _, _)) ->
            case dict.get(modules, module_path) {
              Error(_) -> entries
              Ok(imported_module) -> {
                let binding = import_binding_name(module_path, alias)
                list.fold(
                  imported_module.module.functions,
                  entries,
                  fn(entries, function) {
                    [
                      #(
                        binding <> "." <> function.definition.name,
                        function.definition.parameters
                          |> list.map(fn(parameter) {
                            #(parameter.label, assignment_name(parameter.name))
                          }),
                      ),
                      ..entries
                    ]
                  },
                )
              }
            }
        }
      })
    })
  dict.from_list(list.append(dict.to_list(acc), list.reverse(new_entries)))
}

pub fn has_main_function(
  functions: List(glance.Definition(glance.Function)),
) -> Result(Bool, Nil) {
  functions
  |> list.find(fn(x) {
    case x {
      glance.Definition(
        definition: glance.Function(
          name: "main",
          publicity: glance.Public,
          parameters: [],
          ..,
        ),
        ..,
      ) -> True
      _ -> False
    }
  })
  |> result.replace(True)
}

// The names of all functions in the package that have a python external.
// Calls to externals are emitted with positional arguments, because the
// hand-written binding functions use the parameter names rather than the
// labels a labelled call would emit as keywords.
// The external functions defined in a single module, by bare name. Used to
// recognize local calls to the module's own externals.
fn module_external_names(glance_module: glance.Module) -> List(String) {
  glance_module.functions
  |> list.filter_map(fn(definition) {
    case definition {
      glance.Definition(attributes, function) ->
        case is_python_external(attributes) {
          True -> Ok(function.name)
          False -> Error(Nil)
        }
    }
  })
}

fn is_python_external(attributes: List(glance.Attribute)) -> Bool {
  list.any(attributes, fn(attribute) {
    case attribute {
      glance.Attribute("external", [glance.Variable(_, "python"), _, _]) -> True
      _ -> False
    }
  })
}

fn binding_name(name: String, alias: option.Option(String)) -> String {
  case alias {
    option.Some(alias) -> alias
    option.None -> name
  }
}

// The bare external names visible in a module: its own externals plus externals
// brought in by unqualified imports (`import simplifile.{write_bits}`). A bare
// call to such a name must be treated as an external call so its labelled
// arguments are remapped to the binding's parameter names.
fn module_external_names_with_unqualified(
  glance_module: glance.Module,
  modules: dict.Dict(String, glimpse.Module),
) -> List(String) {
  let own = module_external_names(glance_module)
  let imported =
    glance_module.imports
    |> list.flat_map(fn(definition) {
      case definition {
        glance.Definition(
          _,
          glance.Import(_, module_path, _, _, unqualified_values),
        ) ->
          case dict.get(modules, module_path) {
            Error(_) -> []
            Ok(imported_module) -> {
              let imported_externals =
                module_external_names(imported_module.module)
              unqualified_values
              |> list.filter_map(fn(unqualified) {
                case unqualified {
                  glance.UnqualifiedImport(name, alias) ->
                    case list.contains(imported_externals, name) {
                      True -> Ok(binding_name(name, alias))
                      False -> Error(Nil)
                    }
                }
              })
            }
          }
      }
    })
  list.unique(list.append(own, imported))
}

// Every external function in the package, keyed by the module-qualified name
// `<last_segment>.<function>` so that calls to a *different* module's
// functions are only treated as external when they genuinely are (a bare-name
// match alone would misclassify e.g. `string.append` because `list.append`
// is external).
fn package_externals(
  modules: dict.Dict(String, glimpse.Module),
) -> List(String) {
  modules
  |> dict.to_list
  |> list.flat_map(fn(pair) {
    let #(module_name, module) = pair
    let prefix =
      module_name
      |> string.split("/")
      |> list.last
      |> result.unwrap("")
    module_external_names(module.module)
    |> list.map(fn(name) { prefix <> "." <> name })
  })
  |> list.unique
}
