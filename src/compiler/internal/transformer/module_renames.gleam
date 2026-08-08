import compiler/internal/transformer/patterns
import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string

// When a module imports a submodule (e.g. `import glexer/token`, binding the
// name `token`) and also defines a private top-level value with the same name,
// the generated `def token` would override the `glexer.token` attribute on the
// parent package. Other modules that import the submodule from the parent
// (`from glexer import token`) would then receive the function instead of the
// module. Renaming the import binding cannot avoid this: the `def` clobbers
// the package attribute regardless of the name the import is bound to locally.
//
// So the colliding private value is renamed to a fresh name and every
// reference to it within the module is rewritten. Public values are left
// alone (other modules may import them); their collisions with import
// bindings are handled by renaming the import binding instead.
pub fn rename_private_value_collisions(module: glance.Module) -> glance.Module {
  let import_bindings = module_import_bindings(module)
  let renames = compute_renames(module, import_bindings)
  case dict.size(renames) {
    0 -> module
    _ ->
      glance.Module(
        ..module,
        functions: list.map(module.functions, fn(definition) {
          case definition {
            glance.Definition(attributes, function) ->
              glance.Definition(
                attributes,
                glance.Function(
                  ..function,
                  name: rename_value(function.name, renames),
                  body: rename_statements(
                    function.body,
                    renames,
                    import_bindings,
                    // Parameter names shadow the renamed value in the
                    // body, so references to them must not be renamed.
                    list.map(function.parameters, fn(parameter) {
                      assignment_name(parameter.name)
                    }),
                  ),
                ),
              )
          }
        }),
        constants: list.map(module.constants, fn(definition) {
          case definition {
            glance.Definition(attributes, constant) ->
              glance.Definition(
                attributes,
                glance.Constant(
                  ..constant,
                  name: rename_value(constant.name, renames),
                  value: rename_expression(
                    constant.value,
                    renames,
                    import_bindings,
                    [],
                  ),
                ),
              )
          }
        }),
      )
  }
}

// The names bound by this module's imports: the alias when present, otherwise
// the last segment of the module path.
fn module_import_bindings(module: glance.Module) -> List(String) {
  list.map(module.imports, fn(definition) {
    case definition {
      glance.Definition(_, glance.Import(_, module, alias, _, _)) ->
        module_binding_name(module, alias)
    }
  })
}

fn module_binding_name(
  module: String,
  alias: option.Option(glance.AssignmentName),
) -> String {
  case alias {
    option.Some(assignment) -> assignment_name(assignment)
    option.None ->
      case module |> string.split("/") |> list.reverse {
        [last, ..] -> last
        [] -> panic as "Expected at least one module import"
      }
  }
}

fn compute_renames(
  module: glance.Module,
  import_bindings: List(String),
) -> dict.Dict(String, String) {
  let colliding =
    list.filter(private_value_names(module), fn(name) {
      list.contains(import_bindings, name)
    })
  case colliding {
    [] -> dict.new()
    _ -> {
      let used = compute_used_names(module, import_bindings)
      list.fold(colliding, dict.new(), fn(renames, name) {
        dict.insert(renames, name, fresh_name(name, used, 0))
      })
    }
  }
}

fn compute_used_names(
  module: glance.Module,
  import_bindings: List(String),
) -> List(String) {
  let function_names =
    list.map(module.functions, fn(definition) {
      case definition {
        glance.Definition(_, function) -> function.name
      }
    })
  let constant_names =
    list.map(module.constants, fn(definition) {
      case definition {
        glance.Definition(_, constant) -> constant.name
      }
    })
  list.unique(list.append(
    list.append(function_names, constant_names),
    import_bindings,
  ))
}

fn private_value_names(module: glance.Module) -> List(String) {
  list.append(
    list.fold(module.functions, [], fn(names, definition) {
      case definition {
        glance.Definition(attributes, function) ->
          case function.publicity {
            glance.Private ->
              // External functions do not emit a `def`, so they never
              // clobber a package attribute and do not need renaming.
              case is_external(attributes) {
                True -> names
                False -> [function.name, ..names]
              }
            glance.Public -> names
          }
      }
    }),
    list.fold(module.constants, [], fn(names, definition) {
      case definition {
        glance.Definition(_, constant) ->
          case constant.publicity {
            glance.Private -> [constant.name, ..names]
            glance.Public -> names
          }
      }
    }),
  )
}

fn is_external(attributes: List(glance.Attribute)) -> Bool {
  list.any(attributes, fn(attribute) {
    case attribute {
      glance.Attribute("external", _) -> True
      _ -> False
    }
  })
}

fn fresh_name(name: String, used: List(String), index: Int) -> String {
  let candidate = name <> "_" <> int.to_string(index)
  case list.contains(used, candidate) {
    True -> fresh_name(name, used, index + 1)
    False -> candidate
  }
}

fn rename_value(name: String, renames: dict.Dict(String, String)) -> String {
  result.unwrap(dict.get(renames, name), name)
}

// Walks a list of statements in program order, tracking which names are bound
// so that references to a binding are never renamed.
fn rename_statements(
  statements: List(glance.Statement),
  renames: dict.Dict(String, String),
  module_bindings: List(String),
  in_scope: List(String),
) -> List(glance.Statement) {
  let #(_, renamed) =
    list.fold(statements, #(in_scope, []), fn(state, statement) {
      let #(scope, out) = state
      let renamed = rename_statement(statement, renames, module_bindings, scope)
      let scope = list.unique(list.append(scope, statement_binds(statement)))
      #(scope, [renamed, ..out])
    })
  list.reverse(renamed)
}

fn rename_statement(
  statement: glance.Statement,
  renames: dict.Dict(String, String),
  module_bindings: List(String),
  in_scope: List(String),
) -> glance.Statement {
  case statement {
    glance.Use(location, use_patterns, function) ->
      glance.Use(
        location,
        use_patterns,
        rename_expression(function, renames, module_bindings, in_scope),
      )
    glance.Assignment(location, kind, pattern, annotation, value) ->
      glance.Assignment(
        location,
        kind,
        pattern,
        annotation,
        rename_expression(value, renames, module_bindings, in_scope),
      )
    glance.Assert(location, expression, message) ->
      glance.Assert(
        location,
        rename_expression(expression, renames, module_bindings, in_scope),
        option.map(message, rename_expression(
          _,
          renames,
          module_bindings,
          in_scope,
        )),
      )
    glance.Expression(expression) ->
      glance.Expression(rename_expression(
        expression,
        renames,
        module_bindings,
        in_scope,
      ))
  }
}

// Names bound by a statement. Pattern bindings shadow the top-level value in
// Gleam, so references to them must not be renamed.
fn statement_binds(statement: glance.Statement) -> List(String) {
  case statement {
    glance.Assignment(_, _, pattern, _, _) -> patterns.collect_binds(pattern)
    glance.Use(_, use_patterns, _) ->
      list.flatten(
        list.map(use_patterns, fn(use_pattern) {
          patterns.collect_binds(use_pattern.pattern)
        }),
      )
    _ -> []
  }
}

fn rename_expression(
  expression: glance.Expression,
  renames: dict.Dict(String, String),
  module_bindings: List(String),
  in_scope: List(String),
) -> glance.Expression {
  case expression {
    glance.Int(_, _) | glance.Float(_, _) | glance.String(_, _) -> expression
    glance.Variable(location, name) ->
      case list.contains(in_scope, name) {
        True -> expression
        False -> glance.Variable(location, rename_value(name, renames))
      }
    glance.NegateInt(location, value) ->
      glance.NegateInt(
        location,
        rename_expression(value, renames, module_bindings, in_scope),
      )
    glance.NegateBool(location, value) ->
      glance.NegateBool(
        location,
        rename_expression(value, renames, module_bindings, in_scope),
      )
    glance.Block(location, statements) ->
      glance.Block(
        location,
        rename_statements(statements, renames, module_bindings, in_scope),
      )
    glance.Panic(location, message) ->
      glance.Panic(
        location,
        option.map(message, rename_expression(
          _,
          renames,
          module_bindings,
          in_scope,
        )),
      )
    glance.Todo(location, message) ->
      glance.Todo(
        location,
        option.map(message, rename_expression(
          _,
          renames,
          module_bindings,
          in_scope,
        )),
      )
    glance.Tuple(location, elements) ->
      glance.Tuple(
        location,
        list.map(elements, rename_expression(
          _,
          renames,
          module_bindings,
          in_scope,
        )),
      )
    glance.List(location, elements, rest) ->
      glance.List(
        location,
        list.map(elements, rename_expression(
          _,
          renames,
          module_bindings,
          in_scope,
        )),
        option.map(rest, rename_expression(
          _,
          renames,
          module_bindings,
          in_scope,
        )),
      )
    glance.Fn(location, arguments, return_annotation, body) -> {
      let scope =
        list.append(
          in_scope,
          list.map(arguments, fn(argument) { assignment_name(argument.name) }),
        )
      glance.Fn(
        location,
        arguments,
        return_annotation,
        rename_statements(body, renames, module_bindings, scope),
      )
    }
    glance.RecordUpdate(location, module, constructor, record, fields) ->
      glance.RecordUpdate(
        location,
        module,
        constructor,
        rename_expression(record, renames, module_bindings, in_scope),
        list.map(fields, fn(field) {
          glance.RecordUpdateField(
            field.label,
            option.map(field.item, rename_expression(
              _,
              renames,
              module_bindings,
              in_scope,
            )),
          )
        }),
      )
    glance.FieldAccess(location, container, label) ->
      glance.FieldAccess(
        location,
        rename_container(container, renames, module_bindings, in_scope),
        label,
      )
    glance.Call(location, function, arguments) ->
      glance.Call(
        location,
        rename_expression(function, renames, module_bindings, in_scope),
        list.map(arguments, rename_expression_field(
          _,
          renames,
          module_bindings,
          in_scope,
        )),
      )
    glance.TupleIndex(location, tuple, index) ->
      glance.TupleIndex(
        location,
        rename_expression(tuple, renames, module_bindings, in_scope),
        index,
      )
    glance.FnCapture(
      location,
      label,
      function,
      arguments_before,
      arguments_after,
    ) ->
      glance.FnCapture(
        location,
        label,
        rename_expression(function, renames, module_bindings, in_scope),
        list.map(arguments_before, rename_expression_field(
          _,
          renames,
          module_bindings,
          in_scope,
        )),
        list.map(arguments_after, rename_expression_field(
          _,
          renames,
          module_bindings,
          in_scope,
        )),
      )
    glance.BitString(location, segments) ->
      glance.BitString(
        location,
        list.map(segments, fn(segment) {
          let #(value, options) = segment
          #(
            rename_expression(value, renames, module_bindings, in_scope),
            options,
          )
        }),
      )
    glance.Case(location, subjects, clauses) ->
      glance.Case(
        location,
        list.map(subjects, rename_expression(
          _,
          renames,
          module_bindings,
          in_scope,
        )),
        list.map(clauses, fn(clause) {
          let clause_scope =
            list.unique(list.append(in_scope, clause_binds(clause.patterns)))
          glance.Clause(
            clause.patterns,
            // Guards cannot reference pattern bindings, so they are renamed
            // in the enclosing scope.
            option.map(clause.guard, rename_expression(
              _,
              renames,
              module_bindings,
              in_scope,
            )),
            rename_expression(
              clause.body,
              renames,
              module_bindings,
              clause_scope,
            ),
          )
        }),
      )
    glance.BinaryOperator(location, name, left, right) ->
      glance.BinaryOperator(
        location,
        name,
        rename_expression(left, renames, module_bindings, in_scope),
        rename_expression(right, renames, module_bindings, in_scope),
      )
    glance.Echo(location, expression, message) ->
      glance.Echo(
        location,
        option.map(expression, rename_expression(
          _,
          renames,
          module_bindings,
          in_scope,
        )),
        option.map(message, rename_expression(
          _,
          renames,
          module_bindings,
          in_scope,
        )),
      )
  }
}

// A container that is a module binding is a reference to the imported module,
// not to the renamed value, so it must be left alone.
fn rename_container(
  container: glance.Expression,
  renames: dict.Dict(String, String),
  module_bindings: List(String),
  in_scope: List(String),
) -> glance.Expression {
  case container {
    glance.Variable(location, name) ->
      case
        list.contains(module_bindings, name) || list.contains(in_scope, name)
      {
        True -> container
        False -> glance.Variable(location, rename_value(name, renames))
      }
    _ -> rename_expression(container, renames, module_bindings, in_scope)
  }
}

fn rename_expression_field(
  field: glance.Field(glance.Expression),
  renames: dict.Dict(String, String),
  module_bindings: List(String),
  in_scope: List(String),
) -> glance.Field(glance.Expression) {
  case field {
    glance.LabelledField(label, label_location, item) ->
      glance.LabelledField(
        label,
        label_location,
        rename_expression(item, renames, module_bindings, in_scope),
      )
    glance.UnlabelledField(item) ->
      glance.UnlabelledField(rename_expression(
        item,
        renames,
        module_bindings,
        in_scope,
      ))
    glance.ShorthandField(label, location) ->
      case list.contains(in_scope, label) {
        True -> field
        False -> glance.ShorthandField(rename_value(label, renames), location)
      }
  }
}

fn clause_binds(patterns: List(List(glance.Pattern))) -> List(String) {
  list.flatten(
    list.map(patterns, fn(inner) {
      list.flatten(list.map(inner, patterns.collect_binds))
    }),
  )
}

fn assignment_name(name: glance.AssignmentName) -> String {
  case name {
    glance.Named(string) -> string
    glance.Discarded(string) -> string
  }
}
