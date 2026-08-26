import compiler/internal/comments
import compiler/internal/transformer as internal
import compiler/internal/transformer/functions
import compiler/internal/transformer/module_renames
import compiler/internal/transformer/statements
import compiler/internal/transformer/types
import compiler/python
import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string

// macabre only compiles for the python target. A top-level definition with a
// `@target(...)` attribute is kept only when that attribute lists `python`;
// definitions without a `@target` attribute are kept unconditionally.
fn keep_for_python(definition: glance.Definition(a)) -> Bool {
  case definition {
    glance.Definition(attributes, _) -> attributes |> target_includes_python
  }
}

fn target_includes_python(attributes: List(glance.Attribute)) -> Bool {
  let targets =
    list.filter(attributes, fn(attribute) {
      case attribute {
        glance.Attribute("target", _) -> True
        _ -> False
      }
    })
    |> list.map(fn(attribute) {
      case attribute {
        glance.Attribute(_, arguments) -> arguments
      }
    })
  case targets {
    [] -> True
    _ ->
      list.any(targets, fn(arguments) {
        list.any(arguments, fn(argument) {
          case argument {
            glance.Variable(_, "python") -> True
            _ -> False
          }
        })
      })
  }
}

// Constants are emitted at module level in dependency order: a constant
// whose value references another constant must come after it, otherwise the
// generated Python raises NameError on the forward reference. Real Gleam
// sorts constants the same way. The sort is stable, preserving source order
// among constants that do not depend on one another.
fn sort_constants(
  constants: List(glance.Definition(glance.Constant)),
) -> List(glance.Definition(glance.Constant)) {
  let name_of = fn(constant: glance.Definition(glance.Constant)) {
    constant.definition.name
  }
  let names = list.map(constants, name_of)
  let deps_of =
    dict.from_list(
      list.map(constants, fn(constant) {
        #(
          name_of(constant),
          constant.definition.value
            |> constant_refs
            |> list.filter(fn(name) { list.contains(names, name) })
            |> list.unique,
        )
      }),
    )
  let #(sorted, _) =
    list.fold(constants, #([], constants), fn(state, _constant) {
      let #(placed, remaining) = state
      let placed_names = list.map(placed, name_of)
      let next =
        list.find(remaining, fn(constant) {
          let deps = dict.get(deps_of, name_of(constant)) |> result.unwrap([])
          list.all(deps, fn(dep) { list.contains(placed_names, dep) })
        })
      case next {
        Ok(found) -> #(
          list.append(placed, [found]),
          list.filter(remaining, fn(constant) {
            name_of(constant) != name_of(found)
          }),
        )
        Error(_) -> state
      }
    })
  sorted
}

// The names of constants (and top-level values) referenced by a constant's
// value expression. Only bare variable references matter: a constant can
// reference another constant by name, but a module-qualified access refers
// to a module binding, not a local constant.
fn constant_refs(expression: glance.Expression) -> List(String) {
  case expression {
    glance.Variable(_, name) -> [name]
    glance.Int(_, _) | glance.Float(_, _) | glance.String(_, _) -> []
    glance.NegateInt(_, value) | glance.NegateBool(_, value) ->
      constant_refs(value)
    glance.Block(_, statements) -> constant_statement_refs(statements)
    glance.Panic(_, message) | glance.Todo(_, message) ->
      message |> option.map(constant_refs) |> option.unwrap([])
    glance.Tuple(_, elements) -> list.flatten(list.map(elements, constant_refs))
    glance.List(_, elements, rest) ->
      list.flatten(list.map(elements, constant_refs))
      |> list.append(rest |> option.map(constant_refs) |> option.unwrap([]))
    glance.Fn(_, _, _, body) -> constant_statement_refs(body)
    glance.RecordUpdate(_, _, _, record, fields) ->
      constant_refs(record)
      |> list.append(
        list.flatten(
          list.map(fields, fn(field) {
            case field {
              glance.RecordUpdateField(_, item) ->
                item |> option.map(constant_refs) |> option.unwrap([])
            }
          }),
        ),
      )
    glance.FieldAccess(_, container, _) -> constant_refs(container)
    glance.Call(_, function, arguments) ->
      constant_refs(function)
      |> list.append(list.flatten(list.map(arguments, constant_field_refs)))
    glance.TupleIndex(_, tuple, _) -> constant_refs(tuple)
    glance.FnCapture(_, _, function, arguments_before, arguments_after) ->
      constant_refs(function)
      |> list.append(
        list.flatten(list.map(arguments_before, constant_field_refs)),
      )
      |> list.append(
        list.flatten(list.map(arguments_after, constant_field_refs)),
      )
    glance.BitString(_, segments) ->
      list.flatten(
        list.map(segments, fn(segment) {
          let #(value, options) = segment
          constant_refs(value)
          |> list.append(
            list.flatten(
              list.map(options, fn(option) {
                case option {
                  glance.SizeValueOption(value) -> constant_refs(value)
                  _ -> []
                }
              }),
            ),
          )
        }),
      )
    glance.Case(_, subjects, clauses) ->
      list.flatten(list.map(subjects, constant_refs))
      |> list.append(
        list.flatten(
          list.map(clauses, fn(clause) {
            let refs = case clause {
              glance.Clause(_, guard, body) ->
                constant_refs(body)
                |> list.append(
                  guard
                  |> option.map(constant_refs)
                  |> option.unwrap([]),
                )
            }
            refs
          }),
        ),
      )
    glance.BinaryOperator(_, _, left, right) ->
      constant_refs(left) |> list.append(constant_refs(right))
    glance.Echo(_, expression, message) ->
      expression
      |> option.map(constant_refs)
      |> option.unwrap([])
      |> list.append(message |> option.map(constant_refs) |> option.unwrap([]))
  }
}

fn constant_statement_refs(statements: List(glance.Statement)) -> List(String) {
  list.flatten(
    list.map(statements, fn(statement) {
      case statement {
        glance.Use(_, _, function) -> constant_refs(function)
        glance.Assignment(_, _, _, _, value) -> constant_refs(value)
        glance.Assert(_, expression, message) ->
          constant_refs(expression)
          |> list.append(
            message |> option.map(constant_refs) |> option.unwrap([]),
          )
        glance.Expression(expression) -> constant_refs(expression)
      }
    }),
  )
}

fn constant_field_refs(field: glance.Field(glance.Expression)) -> List(String) {
  case field {
    glance.LabelledField(_, _, item) -> constant_refs(item)
    // The shorthand `f(foo)` desugars to `f(foo: foo)`, referencing the name
    // directly.
    glance.ShorthandField(label, _) -> [label]
    glance.UnlabelledField(item) -> constant_refs(item)
  }
}

pub fn transform(input: glance.Module) -> python.Module {
  transform_with_signatures(input, option.None, option.None, [], [])
}

pub fn transform_with_signatures(
  input: glance.Module,
  function_signatures: option.Option(internal.FunctionSignatures),
  constructor_arities: option.Option(dict.Dict(String, List(String))),
  external_functions: List(String),
  external_qualified: List(String),
) -> python.Module {
  transform_with_comments(
    input,
    function_signatures,
    constructor_arities,
    external_functions,
    external_qualified,
    [],
  )
}

pub fn transform_with_comments(
  input: glance.Module,
  function_signatures: option.Option(internal.FunctionSignatures),
  constructor_arities: option.Option(dict.Dict(String, List(String))),
  external_functions: List(String),
  external_qualified: List(String),
  module_comments: List(comments.Comment),
) -> python.Module {
  transform_module_with_metadata(
    input,
    function_signatures,
    constructor_arities,
    external_functions,
    external_qualified,
    module_comments,
    "",
    "",
    "",
    set.new(),
    dict.new(),
  )
}

pub fn transform_module_with_metadata(
  input: glance.Module,
  function_signatures: option.Option(internal.FunctionSignatures),
  constructor_arities: option.Option(dict.Dict(String, List(String))),
  external_functions: List(String),
  external_qualified: List(String),
  module_comments: List(comments.Comment),
  module_name: String,
  file_path: String,
  module_source: String,
  submodule_names: set.Set(String),
  mangled_submodules: dict.Dict(String, String),
) -> python.Module {
  // Private top-level values colliding with submodule import bindings are
  // renamed first, so the emitted `def` does not clobber the parent package
  // attribute that other modules import the submodule from.
  let input = module_renames.rename_private_value_collisions(input)
  // Definitions gated behind a `@target(...)` attribute that does not list
  // `python` are dropped: macabre only compiles for the python target, and
  // erlang/javascript-targeted code must never leak into python output.
  let input =
    glance.Module(
      imports: list.filter(input.imports, keep_for_python),
      custom_types: list.filter(input.custom_types, keep_for_python),
      type_aliases: list.filter(input.type_aliases, keep_for_python),
      constants: list.filter(input.constants, keep_for_python),
      functions: list.filter(input.functions, keep_for_python),
    )
  let module_aliases =
    list.flat_map(input.imports, fn(import_) {
      case import_ {
        glance.Definition(_, glance.Import(_, module, alias, _, _)) -> [
          module_binding_name(module, alias),
        ]
      }
    })
  let module_paths =
    list.fold(input.imports, dict.new(), fn(paths, import_) {
      case import_ {
        glance.Definition(_, glance.Import(_, module, alias, _, _)) ->
          dict.insert(paths, module_binding_name(module, alias), module)
      }
    })
  let imported_constructors =
    list.fold(input.imports, dict.new(), fn(constructors, import_) {
      case import_ {
        glance.Definition(_, glance.Import(_, module, alias, types, values)) -> {
          // Only unqualified VALUES make a type's fields visible: `import
          // x.{type Document}` brings the type but not its constructors, so
          // the type stays opaque to this module. Keying by unqualified type
          // name as well lets an annotation like `document: Document` find
          // its import's constructor list.
          let names = list.map(values, fn(u) { u.name })
          let binding = module_binding_name(module, alias)
          let constructors = dict.insert(constructors, binding, names)
          list.fold(types, constructors, fn(constructors, u) {
            dict.insert(constructors, u.name, names)
          })
        }
      }
    })
  let module_bindings =
    compute_module_bindings(input, submodule_names, mangled_submodules)
  let #(leading_comments, comments_by_start, trailing_comments) =
    comments.assign_leading_comments(top_level_spans(input), module_comments)
  let module =
    python.empty_module()
    |> list.fold(input.imports, _, fn(module, import_) {
      transform_import(module, import_, module_bindings, mangled_submodules)
    })
    |> list.fold(
      sort_constants(input.constants) |> list.reverse,
      _,
      fn(module, constant) {
        let definition_comments =
          comments_for(comments_by_start, constant.definition.location.start)
        statements.transform_constant(
          internal.TransformerContext(
            ..internal.empty_context(),
            function_signatures: function_signatures,
            module_aliases: module_aliases,
            module_paths: option.Some(module_paths),
            constructor_arities:,
            module_bindings: option.Some(module_bindings),
            imported_constructors: option.Some(imported_constructors),
            external_functions: option.Some(external_functions),
            external_qualified: option.Some(external_qualified),
            module_name: module_name,
            file_path: file_path,
            module_source: module_source,
          ),
          module,
          constant,
          comments.docstring(definition_comments),
          comments.comment_texts(definition_comments),
        )
      },
    )
    |> list.fold(input.functions, _, fn(module, function) {
      transform_function_or_external(
        module,
        function,
        function_signatures,
        module_aliases,
        module_paths,
        constructor_arities,
        option.Some(module_bindings),
        option.Some(imported_constructors),
        option.Some(external_functions),
        option.Some(external_qualified),
        comments_by_start,
        module_name,
        file_path,
        module_source,
      )
    })
    |> list.fold(input.custom_types, _, fn(module, custom_type) {
      transform_custom_type_in_module(module, custom_type, comments_by_start)
    })
  python.Module(
    ..module,
    docstring: comments.docstring(leading_comments),
    comments: list.append(
      comments.comment_lines(leading_comments),
      comments.comment_lines(trailing_comments),
    ),
  )
}

fn comments_for(
  comments_by_start: dict.Dict(Int, List(comments.Comment)),
  start: Int,
) -> List(comments.Comment) {
  dict.get(comments_by_start, start) |> result.unwrap([])
}

// Every top-level definition span in source order, used to attribute leading
// comments to the definition that follows them.
fn top_level_spans(input: glance.Module) -> List(comments.Spanned) {
  let import_spans =
    definition_spans(input.imports, fn(import_) { import_.location })
  let custom_type_spans =
    definition_spans(input.custom_types, fn(custom_type) {
      custom_type.location
    })
  let type_alias_spans =
    definition_spans(input.type_aliases, fn(type_alias) { type_alias.location })
  let constant_spans =
    definition_spans(input.constants, fn(constant) { constant.location })
  let function_spans =
    definition_spans(input.functions, fn(function) { function.location })
  import_spans
  |> list.append(custom_type_spans)
  |> list.append(type_alias_spans)
  |> list.append(constant_spans)
  |> list.append(function_spans)
  |> list.sort(fn(a, b) { int.compare(a.start, b.start) })
}

fn definition_spans(
  definitions: List(glance.Definition(definition)),
  location: fn(definition) -> glance.Span,
) -> List(comments.Spanned) {
  list.map(definitions, fn(definition) {
    case definition {
      glance.Definition(_, definition) ->
        comments.Spanned(
          start: location(definition).start,
          end: location(definition).end,
        )
    }
  })
}

// Names bound at module level by imports (the module binding, e.g. `token`
// for `import glexer/token`). If a top-level function or constant in this
// module has the same name, the import binding is renamed so the emitted
// `def` does not override the import. The same renaming applies when the
// binding collides with a sibling submodule of this package (e.g. importing
// `gleam/string` binds `string`, which must not shadow a `pkg/string`
// submodule).
fn compute_module_bindings(
  input: glance.Module,
  submodule_names: set.Set(String),
  mangled_submodules: dict.Dict(String, String),
) -> dict.Dict(String, String) {
  // A binding needs renaming when it would be clobbered by an import in the
  // generated Python: either the module defines a top-level value of that name
  // (e.g. `qcheck/random` defines `int` and imports `gleam/int`), or a sibling
  // submodule of the package attaches under that name (e.g. `bitty/string`
  // clobbering a `from gleam import string` binding in `bitty`).
  let defined =
    list.append(
      list.append(
        list.map(input.functions, fn(function) {
          case function {
            glance.Definition(_, definition) -> definition.name
          }
        }),
        list.map(input.constants, fn(constant) {
          case constant {
            glance.Definition(_, definition) -> definition.name
          }
        }),
      ),
      set.to_list(submodule_names),
    )
  list.fold(input.imports, dict.new(), fn(bindings, import_) {
    case import_ {
      glance.Definition(_, glance.Import(_, module, alias, _, _)) -> {
        let binding = module_binding_name(module, alias)
        case dict.get(mangled_submodules, module) {
          // A Python package cannot hold both `clip.arg` (a re-exported
          // function) and `clip/arg` (a submodule), because importing the
          // submodule attaches it to the parent package as `clip.arg`,
          // shadowing the function. When the imported submodule's last segment
          // collides with a top-level value of its parent, `mangled_submodules`
          // maps its path to the mangled path used everywhere (`clip/arg_module`),
          // matching the file written on disk. The binding name is the mangled
          // path's last segment. An explicit alias is kept as-is (only the path
          // is mangled), so a reference uses the name the `from` statement
          // actually binds.
          Ok(mangled_path) ->
            case alias {
              option.Some(_) -> dict.insert(bindings, binding, binding)
              option.None ->
                dict.insert(
                  bindings,
                  binding,
                  mangled_path
                    |> string.split("/")
                    |> list.last
                    |> result.unwrap(""),
                )
            }
          _ -> {
            // The import's file is unchanged; only the binding is aliased with
            // an `as` so it is not clobbered.
            case list.contains(defined, binding) {
              True -> dict.insert(bindings, binding, binding <> "_module")
              False -> dict.insert(bindings, binding, binding)
            }
          }
        }
      }
    }
  })
}

// The name a module import binds in the generated Python. For an aliased
// import it is the alias; otherwise it is the last segment of the module
// path (e.g. "project" for `import compiler/project`).
fn module_binding_name(
  module: String,
  alias: option.Option(glance.AssignmentName),
) -> String {
  case alias {
    option.Some(assignment) -> transform_import_alias(assignment)
    option.None ->
      case module |> string.split("/") |> list.reverse {
        [last, ..] -> last
        [] -> panic as "Expected at least one module import"
      }
  }
}

fn transform_function_or_external(
  module: python.Module,
  function: glance.Definition(glance.Function),
  function_signatures: option.Option(internal.FunctionSignatures),
  module_aliases: List(String),
  module_paths: dict.Dict(String, String),
  constructor_arities: option.Option(dict.Dict(String, List(String))),
  module_bindings: option.Option(dict.Dict(String, String)),
  imported_constructors: option.Option(dict.Dict(String, List(String))),
  external_functions: option.Option(List(String)),
  external_qualified: option.Option(List(String)),
  comments_by_start: dict.Dict(Int, List(comments.Comment)),
  module_name: String,
  file_path: String,
  module_source: String,
) -> python.Module {
  case list.filter_map(function.attributes, maybe_extract_external) {
    [] ->
      // A function annotated `@external(erlang, ...)`/`@external(javascript,
      // ...)` with no `@external(python, ...)` and no body has no python
      // implementation. Compiling it as a normal function would emit a silent
      // `def f(): pass`, hiding the missing binding until a confusing runtime
      // error; instead emit a function that raises loudly when called. A
      // function that *does* have a body keeps it: that is Gleam's standard
      // fallback implementation for other targets.
      case has_external_attribute(function.attributes) {
        True ->
          case function.definition.body {
            [] ->
              emit_missing_external_stub(module, function, comments_by_start)
            _ ->
              compile_normal_function(
                module,
                function,
                function_signatures,
                module_aliases,
                module_paths,
                constructor_arities,
                module_bindings,
                imported_constructors,
                external_functions,
                external_qualified,
                comments_by_start,
                module_name,
                file_path,
                module_source,
              )
          }
        False ->
          compile_normal_function(
            module,
            function,
            function_signatures,
            module_aliases,
            module_paths,
            constructor_arities,
            module_bindings,
            imported_constructors,
            external_functions,
            external_qualified,
            comments_by_start,
            module_name,
            file_path,
            module_source,
          )
      }
    [python_import] ->
      transform_python_external(module, function, python_import)
    _ -> panic as "Did not expect more than one external for one function"
  }
}

fn compile_normal_function(
  module: python.Module,
  function: glance.Definition(glance.Function),
  function_signatures: option.Option(internal.FunctionSignatures),
  module_aliases: List(String),
  module_paths: dict.Dict(String, String),
  constructor_arities: option.Option(dict.Dict(String, List(String))),
  module_bindings: option.Option(dict.Dict(String, String)),
  imported_constructors: option.Option(dict.Dict(String, List(String))),
  external_functions: option.Option(List(String)),
  external_qualified: option.Option(List(String)),
  comments_by_start: dict.Dict(Int, List(comments.Comment)),
  module_name: String,
  file_path: String,
  module_source: String,
) -> python.Module {
  let definition_comments =
    comments_for(comments_by_start, function.definition.location.start)
  let python_function =
    functions.transform_top_level_function(
      function.definition,
      function_signatures,
      module_aliases,
      module_paths,
      constructor_arities,
      module_bindings,
      imported_constructors,
      external_functions,
      external_qualified,
      case function.definition.publicity {
        glance.Public -> True
        glance.Private -> False
      },
      module_name,
      file_path,
      module_source,
    )
  python.Module(..module, functions: [
    python.Function(
      ..python_function,
      docstring: comments.docstring(definition_comments),
      comments: comments.comment_lines(definition_comments),
    ),
    ..module.functions
  ])
}

fn has_external_attribute(attributes: List(glance.Attribute)) -> Bool {
  list.any(attributes, fn(attribute) {
    case attribute {
      glance.Attribute("external", _) -> True
      _ -> False
    }
  })
}

// Emits a stub function whose body raises a loud, descriptive runtime error
// when called, instead of silently compiling to `def f(): pass`.
fn emit_missing_external_stub(
  module: python.Module,
  function: glance.Definition(glance.Function),
  comments_by_start: dict.Dict(Int, List(comments.Comment)),
) -> python.Module {
  let definition_comments =
    comments_for(comments_by_start, function.definition.location.start)
  let message =
    "The function "
    <> function.definition.name
    <> " has no python binding (its @external annotations target other"
    <> " platforms)"
  let stub =
    python.Function(
      name: function.definition.name,
      parameters: functions.external_forwarder_parameters(function.definition),
      body: [python.Expression(python.Todo(python.String(message)))],
      public: case function.definition.publicity {
        glance.Public -> True
        glance.Private -> False
      },
      docstring: comments.docstring(definition_comments),
      comments: comments.comment_lines(definition_comments),
    )
  python.Module(..module, functions: [stub, ..module.functions])
}

fn transform_python_external(
  module: python.Module,
  function: glance.Definition(glance.Function),
  python_import: python.Import,
) -> python.Module {
  case python_import {
    python.UnqualifiedImport(binding_module, binding_name) ->
      case binding_name == function.definition.name {
        True ->
          python.Module(..module, imports: [python_import, ..module.imports])
        False -> {
          let alias =
            binding_module
            |> string.replace(".", "_")
            |> string.replace("/", "_")
            |> string.append("_" <> binding_name)
          python.Module(
            ..module,
            imports: [
              python.AliasedUnqualifiedImport(
                binding_module,
                binding_name,
                alias,
              ),
              ..module.imports
            ],
            functions: list.prepend(
              module.functions,
              functions.transform_external_forwarder(function.definition, alias),
            ),
          )
        }
      }
    _ -> python.Module(..module, imports: [python_import, ..module.imports])
  }
}

fn transform_import(
  module: python.Module,
  import_: glance.Definition(glance.Import),
  module_bindings: dict.Dict(String, String),
  mangled_submodules: dict.Dict(String, String),
) -> python.Module {
  let python_imports = case import_ {
    glance.Definition(
      _attributes,
      glance.Import(_, module, alias, _unqualified_types, unqualified_values),
    ) -> {
      let binding = module_binding_name(module, alias)
      // A submodule/parent collision (the submodule's last segment collides
      // with a top-level value of its parent) has its import path mangled to
      // match the file written on disk. A colliding binding from the module's
      // own top-level value (e.g. `qcheck/random` defining `int` and importing
      // `gleam/int`) is just an `as` alias on the `from` statement, leaving the
      // imported module's file untouched.
      let submodule_renamed = case dict.get(mangled_submodules, module) {
        Ok(mangled) -> option.Some(mangled)
        Error(_) -> option.None
      }
      let module_imports =
        transform_module_import(module, alias, submodule_renamed)
      let module_imports = case submodule_renamed {
        option.Some(_) -> module_imports
        option.None ->
          case dict.get(module_bindings, binding) {
            Ok(binding_name) if binding_name != binding -> {
              case module |> string.contains("/") {
                True ->
                  // The plain `import a.b.c` statement must not gain an `as`
                  // alias (its attribute-walk binding form is unreliable), so
                  // only the `from a.b import c` binding entry is aliased.
                  list.map(module_imports, fn(import_) {
                    case import_ {
                      python.QualifiedImport(_) -> import_
                      other -> rename_module_import(other, binding_name)
                    }
                  })
                False ->
                  list.map(module_imports, rename_module_import(_, binding_name))
              }
            }
            _ -> module_imports
          }
      }
      let module_part =
        module
        |> string.replace("/", ".")

      let unqualified =
        unqualified_values
        |> list.map(transform_unqualified_description(_, module_part))
      list.append(module_imports, unqualified)
    }
  }
  python.Module(..module, imports: list.append(module.imports, python_imports))
}

fn transform_module_import(
  module: String,
  alias: option.Option(glance.AssignmentName),
  renamed: option.Option(String),
) -> List(python.Import) {
  // A module path like `glexer/token` is emitted as a plain `import
  // glexer.token` followed by `from glexer import token`. The plain import
  // loads the submodule and attaches it to the parent package under its own
  // name. When the parent module also defines a top-level value with that
  // name (e.g. `glexer.token` re-exported as a function `token`), the
  // submodule would shadow that value, so `renamed` carries its mangled path
  // (`glexer/token_module`) matching the file written on disk, keeping the
  // parent's value reachable as `glexer.token`.
  let full_module = case renamed {
    option.Some(mangled_path) -> string.replace(mangled_path, "/", ".")
    option.None -> string.replace(module, "/", ".")
  }
  let parent_module =
    module
    |> string.split("/")
    |> list.reverse
    |> list.drop(1)
    |> list.reverse
    |> string.join(with: ".")
  let last_segment = case renamed {
    option.Some(mangled_path) ->
      mangled_path |> string.split("/") |> list.last |> result.unwrap("")
    option.None -> module |> string.split("/") |> list.last |> result.unwrap("")
  }
  case alias {
    option.None ->
      // A plain `import a.b.c` only binds `a` in Python, so a nested module
      // path needs a `from` binding for the last segment.
      case module |> string.contains("/") {
        True -> [
          python.QualifiedImport(full_module),
          python.UnqualifiedImport(parent_module, last_segment),
        ]
        False -> [python.QualifiedImport(full_module)]
      }
    option.Some(assignment_name) ->
      case module |> string.contains("/") {
        True -> [
          python.QualifiedImport(full_module),
          python.AliasedUnqualifiedImport(
            parent_module,
            last_segment,
            transform_import_alias(assignment_name),
          ),
        ]
        False -> [
          python.AliasedQualifiedImport(
            full_module,
            transform_import_alias(assignment_name),
          ),
        ]
      }
  }
}

// Rewrites an import's binding entry to a renamed binding (via an `as` alias),
// leaving the imported module's file path untouched. Used when a module's own
// top-level value collides with one of its import bindings.
fn rename_module_import(
  import_: python.Import,
  binding: String,
) -> python.Import {
  case import_ {
    python.QualifiedImport(module) ->
      python.AliasedQualifiedImport(module, binding)
    python.UnqualifiedImport(module, name) ->
      python.AliasedUnqualifiedImport(module, name, binding)
    python.AliasedQualifiedImport(module, _) ->
      python.AliasedQualifiedImport(module, binding)
    python.AliasedUnqualifiedImport(module, name, _) ->
      python.AliasedUnqualifiedImport(module, name, binding)
  }
}

fn transform_import_alias(assignment: glance.AssignmentName) -> String {
  // todo: may need some mapping on discarded names
  case assignment {
    glance.Named(string) -> string
    glance.Discarded(string) -> string
  }
}

fn transform_unqualified_description(
  unqual: glance.UnqualifiedImport,
  module: String,
) -> python.Import {
  case unqual.alias {
    option.None -> python.UnqualifiedImport(module, unqual.name)
    option.Some(alias) ->
      python.AliasedUnqualifiedImport(module, unqual.name, alias)
  }
}

fn transform_custom_type_in_module(
  module: python.Module,
  custom_type: glance.Definition(glance.CustomType),
  comments_by_start: dict.Dict(Int, List(comments.Comment)),
) -> python.Module {
  let definition_comments =
    comments_for(comments_by_start, custom_type.definition.location.start)
  python.Module(..module, custom_types: [
    python.CustomType(
      ..types.transform_custom_type(custom_type.definition),
      docstring: comments.docstring(definition_comments),
      comments: comments.comment_lines(definition_comments),
    ),
    ..module.custom_types
  ])
}

fn maybe_extract_external(
  function_attribute: glance.Attribute,
) -> Result(python.Import, internal.TransformError) {
  case function_attribute {
    glance.Attribute(
      "external",
      [
        glance.Variable(_, "python"),
        glance.String(_, module),
        glance.String(_, name),
      ],
    ) -> Ok(python.UnqualifiedImport(module, name))
    _ -> Error(internal.NotExternal)
  }
}
