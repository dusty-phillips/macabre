import compiler/generator
import compiler/internal/comments
import compiler/internal/transformer as internal
import compiler/package
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
  glance_module
  |> transformer.transform_with_comments(
    option.Some(function_signatures),
    option.Some(constructor_arities),
    external_functions,
    external_qualified,
    comments,
  )
  |> generator.generate
}

pub fn compile_package(
  package: package.GleamPackage,
) -> package.CompiledPackage {
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
        compile_module_with_comments(
          value.module,
          function_signatures(package.package.modules, module_name),
          constructor_arities,
          module_external_names(value.module),
          package_externals(package.package.modules),
          package.comments
            |> dict.get(module_name)
            |> result.unwrap([]),
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
  modules
  |> dict.fold(dict.new(), fn(acc, module_name, module) {
    let prefix =
      module_name
      |> string.split("/")
      |> list.last
      |> result.unwrap(module_name)
    module_arities(module.module)
    |> dict.fold(acc, fn(acc, name, field_names) {
      dict.insert(acc, prefix <> "." <> name, field_names)
    })
  })
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
  modules
  |> dict.fold(dict.new(), fn(acc, _module_name, module) {
    module_arities(module.module)
    |> dict.fold(acc, fn(acc, name, field_names) {
      dict.insert(acc, name, field_names)
    })
  })
}

// References to constructors of an aliased import (e.g.
// `import glexer/token as t`, then `t.LeftParen`) are keyed by the alias, so
// the arity map must also carry `<alias>.<name>` keys.
fn add_import_alias_arities(
  acc: dict.Dict(String, List(String)),
  modules: dict.Dict(String, glimpse.Module),
) -> dict.Dict(String, List(String)) {
  modules
  |> dict.fold(acc, fn(acc, _module_name, module) {
    list.fold(module.module.imports, acc, fn(acc, definition) {
      case definition {
        glance.Definition(_, glance.Import(_, module_path, alias, _, _)) ->
          case dict.get(modules, module_path) {
            Error(_) -> acc
            Ok(imported_module) -> {
              let binding = import_binding_name(module_path, alias)
              module_arities(imported_module.module)
              |> dict.fold(acc, fn(acc, name, field_names) {
                dict.insert(acc, binding <> "." <> name, field_names)
              })
            }
          }
      }
    })
  })
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
  modules
  |> dict.fold(dict.new(), fn(acc, module_name, module) {
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
      False -> []
    }
    list.append(qualified_entries, local_entries)
    |> list.fold(acc, fn(acc, entry) {
      let #(key, params) = entry
      dict.insert(acc, key, params)
    })
  })
  |> add_import_alias_signatures(modules)
}

// `use` callbacks resolve against the aliased module name (e.g.
// `use <- t.try_fold(...)` for `import gleam/list as t`), so the signature
// map must also carry `<alias>.<name>` keys.
fn add_import_alias_signatures(
  acc: internal.FunctionSignatures,
  modules: dict.Dict(String, glimpse.Module),
) -> internal.FunctionSignatures {
  modules
  |> dict.fold(acc, fn(acc, _module_name, module) {
    list.fold(module.module.imports, acc, fn(acc, definition) {
      case definition {
        glance.Definition(_, glance.Import(_, module_path, alias, _, _)) ->
          case dict.get(modules, module_path) {
            Error(_) -> acc
            Ok(imported_module) -> {
              let binding = import_binding_name(module_path, alias)
              list.fold(
                imported_module.module.functions,
                acc,
                fn(acc, function) {
                  dict.insert(
                    acc,
                    binding <> "." <> function.definition.name,
                    function.definition.parameters
                      |> list.map(fn(parameter) {
                        #(parameter.label, assignment_name(parameter.name))
                      }),
                  )
                },
              )
            }
          }
      }
    })
  })
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
        case
          list.any(attributes, fn(attribute) {
            case attribute {
              glance.Attribute("external", [glance.Variable(_, "python"), _, _]) ->
                True
              _ -> False
            }
          })
        {
          True -> Ok(function.name)
          False -> Error(Nil)
        }
    }
  })
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
