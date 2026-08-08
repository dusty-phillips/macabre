import compiler/python
import gleam/dict
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/set

// Gleam pattern captures are scoped to their own case clause, but Python
// `match` statement captures are scoped to the enclosing function. This means
// a name bound by one arm's pattern (or guard) becomes a local variable of the
// generated `_fn_case_N` function, which breaks other arms that reference the
// same name from the enclosing scope.
//
//     case input {
//       ["\"", ..input] -> parse_key_quoted(input, "\"", "")   // binds input
//       _ -> parse_key_bare(input, "")                          // outer input
//     }
//
// Here the first arm binds `input` in the pattern, so Python treats `input` as
// a local of the whole match function and the second arm's reference to the
// outer `input` fails with UnboundLocalError.
//
// To fix this we detect names that are bound by one arm's pattern, guard, or
// body but referenced (without being bound) in another arm of the same match,
// and rename the bindings to fresh names consistently within their own arm.
// This runs inside the single block-level pass, when a match statement is
// reached: `resolve_match_cases` below.

// Gleam `let` bindings are scoped from their binding onwards within a block,
// but Python scopes simple assignments to the whole enclosing function. This
// means a name bound at the top level of a generated function body that also
// references a name from the enclosing scope breaks, because Python treats the
// binding name as a local of the whole function.
//
//     fn parse_key(input, segments) {
//       use segment, input <- do(parse_key_segment(input))
//       let segments = [segment, ..segments]   // RHS segments = outer param
//       ...
//     }
//
// Desugars to a nested function whose body binds `segments` while referencing
// the outer `segments` in its own right hand side. Python makes `segments` a
// local of the nested function, so the right hand side fails with
// UnboundLocalError.
//
// To fix this we detect names that are bound at the top level of a function
// body but also referenced from the enclosing scope, and rename the bindings
// (and all references to them after the binding) to fresh names, leaving the
// references that come before the binding pointing at the enclosing scope.
pub fn resolve_block_shadowing(
  statements: List(python.Statement),
  parameter_names: List(String),
  reserved: List(String),
  pool: dict.Dict(String, Int),
) -> #(List(python.Statement), dict.Dict(String, Int)) {
  let initial_scope = set.from_list(parameter_names)

  let #(_, outer_refs, all_binds) =
    list.fold(statements, #(initial_scope, [], []), fn(acc, statement) {
      let #(scope, refs, binds) = acc
      let more_refs = statement_refs(statement, scope)
      let more_binds = all_nested_binds(statement)
      #(
        set.union(scope, set.from_list(top_level_binds(statement))),
        list.append(refs, more_refs),
        list.append(binds, more_binds),
      )
    })

  let collisions =
    all_binds
    |> list.filter(fn(name) {
      list.any(outer_refs, fn(referenced) { referenced == name })
    })
    |> list.unique

  case collisions {
    _ -> {
      let #(renames, pool) = case collisions {
        [] -> #(dict.new(), pool)
        _ -> {
          let used =
            set.from_list(all_binds)
            |> set.union(set.from_list(outer_refs))
            |> set.union(set.from_list(reserved))
            |> set.union(set.from_list(parameter_names))
          list.fold(collisions, #(dict.new(), pool), fn(acc, name) {
            let #(renames, pool) = acc
            let #(fresh, pool) = fresh_name(name, used, pool)
            #(dict.insert(renames, name, fresh), pool)
          })
        }
      }

      let #(_, _, _, _, _, _, reversed, pool) =
        list.fold(
          statements,
          #(
            initial_scope,
            set.new(),
            set.new(),
            renames,
            dict.new(),
            dict.new(),
            [],
            pool,
          ),
          fn(acc, statement) {
            let #(
              scope,
              cross_scope,
              bound,
              renames,
              cross_renames,
              own_cross,
              out,
              pool,
            ) = acc
            let active_renames =
              active_renames_for(
                renames,
                cross_renames,
                own_cross,
                scope,
                cross_scope,
              )
            let #(renamed, pool) =
              statement
              |> rename_statement(active_renames, set.new(), pool)
            let #(renamed, renames, own_cross, pool) =
              rename_binding_targets(renamed, renames, own_cross, bound, pool)
            let #(renamed, pool) =
              resolve_nested_binds(
                renamed,
                renames,
                cross_renames,
                own_cross,
                scope,
                cross_scope,
                bound,
                pool,
              )
            let next_scope =
              set.union(scope, set.from_list(top_level_binds(statement)))
            let next_cross_scope =
              set.union(cross_scope, set.from_list(top_level_binds(statement)))
            let next_bound =
              set.union(bound, set.from_list(top_level_binds(statement)))
            #(
              next_scope,
              next_cross_scope,
              next_bound,
              renames,
              cross_renames,
              own_cross,
              [renamed, ..out],
              pool,
            )
          },
        )
      #(list.reverse(reversed), pool)
    }
  }
}

// The names of a function's parameters, for seeding the scope when resolving
// block shadowing. Parameters are in scope from the start of the body, so
// references to them are never treated as references to the enclosing scope.
pub fn function_parameter_names(
  parameters: List(python.FunctionParameter),
) -> List(String) {
  list.filter_map(parameters, fn(parameter) {
    case parameter {
      python.NameParam(name) -> Ok(name)
      python.DiscardParam(_) -> Error(Nil)
    }
  })
}

// Renames function parameters that collide with imported module bindings, e.g.
// `import compiler/project` followed by `fn load(project: project.Project)`.
// The generated Python has `from compiler import project` (a module-level
// binding) and `def load(project):` — the parameter shadows the module, so
// module-qualified calls inside the function (which we mark with the
// `python.Module` node) keep resolving to the module binding while every
// reference to the parameter is renamed to a fresh name. Returns the renamed
// parameters alongside the renamed body so tail-call resolution can use the
// final parameter names.
pub fn resolve_module_shadowing(
  statements: List(python.Statement),
  parameters: List(python.FunctionParameter),
  module_aliases: List(String),
  pool: dict.Dict(String, Int),
) -> #(
  List(python.FunctionParameter),
  List(python.Statement),
  dict.Dict(String, Int),
) {
  let parameter_names = function_parameter_names(parameters)

  let collisions =
    parameter_names
    |> list.filter(fn(name) { list.contains(module_aliases, name) })
    |> list.unique

  case collisions {
    [] -> #(parameters, statements, pool)
    _ -> {
      let used =
        set.from_list(parameter_names)
        |> set.union(set.from_list(module_aliases))
      let #(renames, pool) =
        list.fold(collisions, #(dict.new(), pool), fn(acc, name) {
          let #(renames, pool) = acc
          let #(fresh, pool) = fresh_name(name, used, pool)
          #(dict.insert(renames, name, fresh), pool)
        })

      let renamed_parameters =
        list.map(parameters, fn(parameter) {
          case parameter {
            python.NameParam(name) ->
              python.NameParam(result.unwrap(dict.get(renames, name), name))
            python.DiscardParam(_) -> parameter
          }
        })

      let used_for_locals =
        set.from_list(dict.values(renames))
        |> set.union(used)
        // Names bound inside nested functions and match arms (e.g. a
        // case-branch local that the case-level shadowing pass renamed) are
        // locals of the whole generated function in Python, so a fresh name
        // minted here must not collide with them.
        |> set.union(
          set.from_list(list.flatten(list.map(statements, all_nested_binds))),
        )
        |> set.union(
          set.from_list(list.flatten(list.map(statements, all_case_binds))),
        )
        |> set.union(
          set.from_list(
            list.flatten(list.map(statements, statement_refs(_, set.new()))),
          ),
        )

      let #(renamed_statements, pool) =
        rename_module_shadowed(statements, renames, used_for_locals, pool)

      #(renamed_parameters, renamed_statements, pool)
    }
  }
}

// Renames references to module-shadowed parameters in a function body in
// program order. A binding target that shadows a renamed parameter is a NEW
// local, distinct from the parameter, so it gets its own fresh name and later
// references to it use that name; references before the bind (e.g. in the
// bind's own right hand side) refer to the parameter and use the parameter's
// rename. Without this the bind target and the parameter reference would
// collapse onto the same name, and Python would treat a reference made before
// a same-scope assignment as referencing the (unbound) local.
fn rename_module_shadowed(
  statements: List(python.Statement),
  param_renames: dict.Dict(String, String),
  used: set.Set(String),
  pool: dict.Dict(String, Int),
) -> #(List(python.Statement), dict.Dict(String, Int)) {
  let #(_, reversed, pool) =
    list.fold(statements, #(param_renames, [], pool), fn(acc, statement) {
      let #(renaming, out, pool) = acc
      let #(renamed, renaming, pool) =
        rename_module_statement(statement, renaming, used, pool)
      #(renaming, [renamed, ..out], pool)
    })
  #(list.reverse(reversed), pool)
}

// Renames a statement in program order during module shadowing. The `renaming`
// dict maps each renamed name to the name currently in effect for references
// (the parameter's rename before any shadowing bind, the bind's fresh name
// after it); each statement returns the dict updated with fresh names for its
// own binding targets that shadow a renamed name.
fn rename_module_statement(
  statement: python.Statement,
  renaming: dict.Dict(String, String),
  used: set.Set(String),
  pool: dict.Dict(String, Int),
) -> #(python.Statement, dict.Dict(String, String), dict.Dict(String, Int)) {
  case statement {
    python.SimpleAssignment(name, value) -> {
      let #(target, updated, pool) = shadow_target(name, renaming, used, pool)
      #(
        python.SimpleAssignment(
          target,
          rename_expression(value, renaming, set.new()),
        ),
        updated,
        pool,
      )
    }
    python.MultipleAssignment(names, value) -> {
      let #(renamed_names, updated, pool) =
        list.fold(names, #([], renaming, pool), fn(acc, name) {
          let #(out, renaming, pool) = acc
          let #(target, renaming, pool) =
            shadow_target(name, renaming, used, pool)
          #([target, ..out], renaming, pool)
        })
      #(
        python.MultipleAssignment(
          list.reverse(renamed_names),
          rename_expression(value, renaming, set.new()),
        ),
        updated,
        pool,
      )
    }
    python.Expression(expression) -> #(
      python.Expression(rename_expression(expression, renaming, set.new())),
      renaming,
      pool,
    )
    python.Return(expression) -> #(
      python.Return(rename_expression(expression, renaming, set.new())),
      renaming,
      pool,
    )
    python.FunctionDef(function) -> {
      let #(renamed_body, pool) =
        rename_module_shadowed(function.body, renaming, used, pool)
      let renamed_function =
        python.Function(
          ..function,
          parameters: list.map(function.parameters, rename_function_parameter(
            _,
            renaming,
          )),
          body: renamed_body,
        )
      #(python.FunctionDef(renamed_function), renaming, pool)
    }
    python.Match(subject, cases) -> {
      let #(renamed_cases, pool) =
        list.fold(cases, #([], pool), fn(acc, match_case) {
          let #(out, pool) = acc
          let #(renamed, pool) =
            rename_module_case(match_case, renaming, used, pool)
          #([renamed, ..out], pool)
        })
      #(
        python.Match(
          subject: rename_expression(subject, renaming, set.new()),
          cases: list.reverse(renamed_cases),
        ),
        renaming,
        pool,
      )
    }
    python.While(condition, body) -> {
      let #(renamed_body, pool) =
        rename_module_shadowed(body, renaming, used, pool)
      #(
        python.While(
          rename_expression(condition, renaming, set.new()),
          renamed_body,
        ),
        renaming,
        pool,
      )
    }
  }
}

// The fresh name for a binding target that shadows a renamed name, plus the
// renaming dict updated so later references to the target use the fresh name.
// A target whose name is not being renamed keeps its name and the dict.
fn shadow_target(
  name: String,
  renaming: dict.Dict(String, String),
  used: set.Set(String),
  pool: dict.Dict(String, Int),
) -> #(String, dict.Dict(String, String), dict.Dict(String, Int)) {
  case dict.has_key(renaming, name) {
    False -> #(name, renaming, pool)
    True -> {
      let #(fresh, pool) = fresh_name(name, used, pool)
      #(fresh, dict.insert(renaming, name, fresh), pool)
    }
  }
}

fn rename_module_case(
  match_case: python.MatchCase,
  renaming: dict.Dict(String, String),
  used: set.Set(String),
  pool: dict.Dict(String, Int),
) -> #(python.MatchCase, dict.Dict(String, Int)) {
  let python.MatchCase(pattern, guard, body) = match_case
  // Names the case pattern binds are locals of the whole generated match
  // function; references to them in the body use the original name (matching
  // the unrenamed pattern), so they are excluded from the renaming. The
  // pattern itself keeps the original names.
  let local_renames =
    dict.filter(renaming, fn(name, _) {
      !list.contains(pattern_binds(pattern), name)
    })
  let #(renamed_body, pool) =
    rename_module_shadowed(body, local_renames, used, pool)
  #(
    python.MatchCase(
      pattern,
      option.map(guard, rename_expression(_, local_renames, set.new())),
      renamed_body,
    ),
    pool,
  )
}

// Names bound by a top level assignment in a function body. These become
// locals of the whole generated function in Python.
fn top_level_binds(statement: python.Statement) -> List(String) {
  case statement {
    python.SimpleAssignment(name, _) -> [name]
    python.MultipleAssignment(names, _) -> names
    python.Expression(_)
    | python.Return(_)
    | python.FunctionDef(_)
    | python.Match(_, _)
    | python.While(_, _) -> []
  }
}

// Renames the target names of top level assignments. Used after renaming the
// references in a statement, so the binding target of a name that is bound
// before any reference to it still gets renamed.
// Renames the targets of top-level assignments in a function body. A target
// whose name is being renamed gets the rename — unless the name is already
// bound in the current scope, meaning this is a REBIND that shadows a
// previously-renamed local (e.g. two `let crossed = ...` in one function).
// Python scopes the rebind to the whole generated function, so the rebind
// must get its own fresh name from the shared pool (mirroring module
// shadowing's `shadow_target`), with later references in that scope using the
// fresh name.
fn rename_binding_targets(
  statement: python.Statement,
  renames: dict.Dict(String, String),
  own_cross: dict.Dict(String, String),
  bound: set.Set(String),
  pool: dict.Dict(String, Int),
) -> #(
  python.Statement,
  dict.Dict(String, String),
  dict.Dict(String, String),
  dict.Dict(String, Int),
) {
  case statement {
    python.SimpleAssignment(name, value) -> {
      case dict.has_key(own_cross, name) {
        True -> {
          let #(target, own_cross, pool) =
            cross_target(name, renames, own_cross, bound, pool)
          #(python.SimpleAssignment(target, value), renames, own_cross, pool)
        }
        False -> {
          let #(target, renames, pool) =
            block_shadow_target(name, renames, own_cross, bound, pool)
          #(python.SimpleAssignment(target, value), renames, own_cross, pool)
        }
      }
    }
    python.MultipleAssignment(names, value) -> {
      let #(renamed_names, renames, own_cross, pool) =
        list.fold(names, #([], renames, own_cross, pool), fn(acc, name) {
          let #(out, renames, own_cross, pool) = acc
          let #(target, renames, own_cross, pool) = case
            dict.has_key(own_cross, name)
          {
            True -> {
              let #(target, own_cross, pool) =
                cross_target(name, renames, own_cross, bound, pool)
              #(target, renames, own_cross, pool)
            }
            False -> {
              let #(target, renames, pool) =
                block_shadow_target(name, renames, own_cross, bound, pool)
              #(target, renames, own_cross, pool)
            }
          }
          #([target, ..out], renames, own_cross, pool)
        })
      #(
        python.MultipleAssignment(list.reverse(renamed_names), value),
        renames,
        own_cross,
        pool,
      )
    }
    python.Expression(_)
    | python.Return(_)
    | python.FunctionDef(_)
    | python.Match(_, _)
    | python.While(_, _) -> #(statement, renames, own_cross, pool)
  }
}

// The fresh name for a cross-renamed binding target (a name the case itself
// binds that collides with another arm's references) that rebinds a name
// already bound earlier in this program-order walk. The case's own renaming
// dict is updated so later references to the target use the fresh name.
fn cross_target(
  name: String,
  renames: dict.Dict(String, String),
  own_cross: dict.Dict(String, String),
  bound: set.Set(String),
  pool: dict.Dict(String, Int),
) -> #(String, dict.Dict(String, String), dict.Dict(String, Int)) {
  let plain = result.unwrap(dict.get(own_cross, name), name)
  case set.contains(bound, name) {
    False -> #(plain, own_cross, pool)
    True -> {
      let used =
        set.from_list(dict.values(renames))
        |> set.union(set.from_list(dict.values(own_cross)))
      let #(fresh, pool) = fresh_name(name, used, pool)
      #(fresh, dict.insert(own_cross, name, fresh), pool)
    }
  }
}

// The fresh name for a binding target that shadows a renamed name, plus the
// renaming dict updated so later references to the target use the fresh name.
// A target whose name is not being renamed keeps its name and the dict. A
// target that rebinds a name already bound by a previous statement in this
// program-order walk (e.g. a second `let crossed = ...`) is a new local
// shadowing the first, and gets a fresh name from the shared pool (like
// module shadowing's `shadow_target`); later references to it in this scope
// use the fresh name. The `bound` set holds names bound by earlier
// statements — parameters are NOT included, so a first bind shadowing a
// parameter still takes the plain rename. Rebinds are always freshened, even
// when the name is not being renamed: a closure inside the same scope may
// reference the earlier binding (e.g. a `use` callback rebinding a name its
// own right hand side references from the enclosing scope), and Python would
// make the closure see the rebind instead.
fn block_shadow_target(
  name: String,
  renames: dict.Dict(String, String),
  own_cross: dict.Dict(String, String),
  bound: set.Set(String),
  pool: dict.Dict(String, Int),
) -> #(String, dict.Dict(String, String), dict.Dict(String, Int)) {
  case set.contains(bound, name) {
    True -> {
      let used =
        set.from_list(dict.values(renames))
        |> set.union(set.from_list(dict.values(own_cross)))
      let #(fresh, pool) = fresh_name(name, used, pool)
      #(fresh, dict.insert(renames, name, fresh), pool)
    }
    False ->
      case dict.has_key(renames, name) {
        False -> #(name, renames, pool)
        True -> #(result.unwrap(dict.get(renames, name), name), renames, pool)
      }
  }
}

// Names bound by a case's pattern, guard, and destructuring assignments. These
// become locals of the generated match function.
fn case_binds(match_case: python.MatchCase) -> List(String) {
  let python.MatchCase(pattern, guard, body) = match_case
  let pattern_binds = pattern_binds(pattern)
  let guard_binds = option.unwrap(option.map(guard, expression_binds), [])
  let body_binds = list.flatten(list.map(body, statement_binds))
  pattern_binds |> list.append(guard_binds) |> list.append(body_binds)
}

// References in a case's guard and body that come from the enclosing scope,
// i.e. excluding names bound before they are referenced. The body is walked
// in program order (like `rename_case_body`), so a reference to a name in the
// right hand side of its own binding still counts: it resolves to the
// enclosing scope and the binding must be renamed.
fn case_refs(
  match_case: python.MatchCase,
  in_scope: set.Set(String),
) -> List(String) {
  let python.MatchCase(pattern, guard, body) = match_case
  let pattern_binds = pattern_binds(pattern)
  let guard_binds = option.unwrap(option.map(guard, expression_binds), [])
  let body_scope =
    in_scope
    |> set.union(set.from_list(pattern_binds))
    |> set.union(set.from_list(guard_binds))
  let guard_refs =
    option.unwrap(option.map(guard, expression_refs(_, in_scope)), [])
    |> list.filter(fn(name) {
      !list.contains(pattern_binds, name) && !list.contains(guard_binds, name)
    })
  let refs =
    pattern_refs(pattern)
    |> list.append(guard_refs)
    |> list.append(body_refs_in_order(body, body_scope))
  refs
}

fn body_refs_in_order(
  statements: List(python.Statement),
  initial_scope: set.Set(String),
) -> List(String) {
  let #(_, refs) =
    list.fold(statements, #(initial_scope, []), fn(acc, statement) {
      let #(scope, out) = acc
      let more_refs = deep_statement_refs(statement, scope)
      let next_scope =
        set.union(scope, set.from_list(top_level_binds(statement)))
      #(next_scope, list.append(out, more_refs))
    })
  refs
}

// Module-qualified constructors in patterns reference the imported module
// binding (e.g. `token.EndOfFile()`). A pattern capture of the same name in
// another arm would shadow it at runtime, because Python match captures are
// scoped to the whole function.
fn pattern_refs(pattern: python.Pattern) -> List(String) {
  case pattern {
    python.PatternConstructor(module, _, arguments) ->
      list.append(
        option.unwrap(option.map(module, fn(name) { [name] }), []),
        list.flatten(
          list.map(arguments, fn(field) {
            case field {
              python.LabelledField(_, item) -> pattern_refs(item)
              python.UnlabelledField(item) -> pattern_refs(item)
            }
          }),
        ),
      )
    python.PatternAssignment(inner, _) -> pattern_refs(inner)
    python.PatternTuple(patterns) ->
      list.flatten(list.map(patterns, pattern_refs))
    python.PatternList(elems, rest) ->
      list.flatten(list.map(elems, pattern_refs))
      |> list.append(option.unwrap(option.map(rest, pattern_refs), []))
    python.PatternAlternate(patterns) ->
      list.flatten(list.map(patterns, pattern_refs))
    python.PatternWildcard
    | python.PatternInt(_)
    | python.PatternFloat(_)
    | python.PatternString(_)
    | python.PatternVariable(_) -> []
  }
}

// A fresh name that doesn't collide with any name used in the match or the
// reserved `_case_subject`. All shadowing passes share one pool of per-base
// counters so `state` becomes `state_0`, `state_1`, `state_2`... and no two
// passes can independently mint the same fresh name.
pub fn fresh_name(
  name: String,
  used: set.Set(String),
  pool: dict.Dict(String, Int),
) -> #(String, dict.Dict(String, Int)) {
  let index = dict.get(pool, name) |> result.unwrap(0)
  let candidate = name <> "_" <> int.to_string(index)
  case set.contains(used, candidate) || candidate == "_case_subject" {
    True -> fresh_name(name, used, dict.insert(pool, name, index + 1))
    False -> #(candidate, dict.insert(pool, name, index + 1))
  }
}

fn pattern_binds(pattern: python.Pattern) -> List(String) {
  case pattern {
    python.PatternVariable(name) -> [name]
    python.PatternAssignment(inner, name) -> [name, ..pattern_binds(inner)]
    python.PatternTuple(patterns) ->
      list.flatten(list.map(patterns, pattern_binds))
    python.PatternList(elems, rest) ->
      list.flatten(list.map(elems, pattern_binds))
      |> list.append(option.unwrap(option.map(rest, pattern_binds), []))
    python.PatternAlternate(patterns) ->
      list.flatten(list.map(patterns, pattern_binds))
    python.PatternConstructor(_, _, arguments) ->
      list.flatten(
        list.map(arguments, fn(field) {
          case field {
            python.LabelledField(_, item) -> pattern_binds(item)
            python.UnlabelledField(item) -> pattern_binds(item)
          }
        }),
      )
    python.PatternWildcard
    | python.PatternInt(_)
    | python.PatternFloat(_)
    | python.PatternString(_) -> []
  }
}

// Names bound by assignment expressions anywhere in an expression, e.g. the
// `(path := ...)` walrus in a concatenation pattern guard. Walrus bindings are
// often nested inside the boolean structure of the guard.
fn expression_binds(expression: python.Expression) -> List(String) {
  case expression {
    python.AssignmentExpression(name, value) -> [
      name,
      ..expression_binds(value)
    ]
    python.String(_)
    | python.Number(_)
    | python.Bool(_)
    | python.Nil
    | python.ModuleRef(_)
    | python.Variable(_) -> []
    python.Tuple(elements) -> list.flatten(list.map(elements, expression_binds))
    python.Negate(inner)
    | python.Not(inner)
    | python.Panic(inner)
    | python.Todo(inner)
    | python.IsNotNone(inner) -> expression_binds(inner)
    python.Lambda(_, body) -> expression_binds(body)
    python.List(elements) -> list.flatten(list.map(elements, expression_binds))
    python.ListWithRest(elements, rest) ->
      list.flatten(list.map(elements, expression_binds))
      |> list.append(expression_binds(rest))
    python.TupleIndex(tuple, _) -> expression_binds(tuple)
    python.FieldAccess(container, _) -> expression_binds(container)
    python.Call(function, arguments) ->
      expression_binds(function)
      |> list.append(
        list.flatten(
          list.map(arguments, fn(field) {
            case field {
              python.LabelledField(_, item) -> expression_binds(item)
              python.UnlabelledField(item) -> expression_binds(item)
            }
          }),
        ),
      )
    python.RecordUpdate(record, fields) ->
      expression_binds(record)
      |> list.append(
        list.flatten(
          list.map(fields, fn(field) {
            case field {
              python.LabelledField(_, item) -> expression_binds(item)
              python.UnlabelledField(item) -> expression_binds(item)
            }
          }),
        ),
      )
    python.BinaryOperator(_, left, right) ->
      expression_binds(left) |> list.append(expression_binds(right))
    python.Slice(container, start, end) ->
      expression_binds(container)
      |> list.append(expression_binds(start))
      |> list.append(option.unwrap(option.map(end, expression_binds), []))
    python.BitString(segments) ->
      list.flatten(
        list.map(segments, fn(segment) {
          let python.BitStringSegment(value, _) = segment
          expression_binds(value)
        }),
      )
  }
}

// Names of a lambda's parameters. Lambdas store their arguments as `Variable`
// expressions, so we extract the name from each.
fn lambda_param_names(args: List(python.Expression)) -> List(String) {
  list.filter_map(args, fn(arg) {
    case arg {
      python.Variable(name) -> Ok(name)
      _ -> Error(Nil)
    }
  })
}

fn expression_refs(
  expression: python.Expression,
  in_scope: set.Set(String),
) -> List(String) {
  case expression {
    python.Variable(name) ->
      case set.contains(in_scope, name) {
        True -> []
        False -> [name]
      }
    python.ModuleRef(name) -> [name]
    python.String(_) | python.Number(_) | python.Bool(_) | python.Nil -> []
    python.Tuple(elements) ->
      list.flatten(list.map(elements, expression_refs(_, in_scope)))
    python.Negate(inner)
    | python.Not(inner)
    | python.Panic(inner)
    | python.Todo(inner)
    | python.IsNotNone(inner) -> expression_refs(inner, in_scope)
    python.Lambda(args, body) ->
      expression_refs(
        body,
        set.union(in_scope, set.from_list(lambda_param_names(args))),
      )
    python.List(elements) ->
      list.flatten(list.map(elements, expression_refs(_, in_scope)))
    python.ListWithRest(elements, rest) ->
      list.flatten(list.map(elements, expression_refs(_, in_scope)))
      |> list.append(expression_refs(rest, in_scope))
    python.TupleIndex(tuple, _) -> expression_refs(tuple, in_scope)
    python.FieldAccess(container, _) -> expression_refs(container, in_scope)
    python.Call(function, arguments) ->
      expression_refs(function, in_scope)
      |> list.append(
        list.flatten(
          list.map(arguments, fn(field) {
            case field {
              python.LabelledField(_, item) -> expression_refs(item, in_scope)
              python.UnlabelledField(item) -> expression_refs(item, in_scope)
            }
          }),
        ),
      )
    python.RecordUpdate(record, fields) ->
      expression_refs(record, in_scope)
      |> list.append(
        list.flatten(
          list.map(fields, fn(field) {
            case field {
              python.LabelledField(_, item) -> expression_refs(item, in_scope)
              python.UnlabelledField(item) -> expression_refs(item, in_scope)
            }
          }),
        ),
      )
    python.BinaryOperator(_, left, right) ->
      expression_refs(left, in_scope)
      |> list.append(expression_refs(right, in_scope))
    python.Slice(container, start, end) ->
      expression_refs(container, in_scope)
      |> list.append(expression_refs(start, in_scope))
      |> list.append(
        option.unwrap(option.map(end, expression_refs(_, in_scope)), []),
      )
    python.AssignmentExpression(name, value) -> [
      name,
      ..expression_refs(value, in_scope)
    ]
    python.BitString(segments) ->
      list.flatten(
        list.map(segments, fn(segment) {
          let python.BitStringSegment(value, _) = segment
          expression_refs(value, in_scope)
        }),
      )
  }
}

// Names bound by the statements in a case body. These become locals of the
// generated match function.
fn statement_binds(statement: python.Statement) -> List(String) {
  case statement {
    python.SimpleAssignment(name, value) -> [name, ..expression_binds(value)]
    python.MultipleAssignment(names, value) ->
      names |> list.append(expression_binds(value))
    python.Expression(expression) | python.Return(expression) ->
      expression_binds(expression)
    python.FunctionDef(_) -> []
    python.Match(_, _) -> []
    python.While(_, body) -> list.flatten(list.map(body, statement_binds))
  }
}

fn statement_refs(
  statement: python.Statement,
  in_scope: set.Set(String),
) -> List(String) {
  case statement {
    python.Expression(expression) | python.Return(expression) ->
      expression_refs(expression, in_scope)
    python.SimpleAssignment(_, value) -> expression_refs(value, in_scope)
    python.MultipleAssignment(_, value) -> expression_refs(value, in_scope)
    python.FunctionDef(function) ->
      function.body
      |> list.map(statement_refs(_, function_scope(function, in_scope)))
      |> list.flatten
    python.Match(subject, _cases) -> expression_refs(subject, in_scope)
    python.While(condition, body) ->
      expression_refs(condition, in_scope)
      |> list.append(list.flatten(list.map(body, statement_refs(_, in_scope))))
  }
}

// Like `statement_refs` but also descends into match case bodies. Used for
// cross-arm collision detection, which must see references nested inside
// other matches (e.g. a reference to an enclosing scope's `tokens` inside a
// nested case in another arm).
fn deep_statement_refs(
  statement: python.Statement,
  in_scope: set.Set(String),
) -> List(String) {
  case statement {
    python.Expression(expression) | python.Return(expression) ->
      expression_refs(expression, in_scope)
    python.SimpleAssignment(_, value) -> expression_refs(value, in_scope)
    python.MultipleAssignment(_, value) -> expression_refs(value, in_scope)
    python.FunctionDef(function) ->
      function.body
      |> list.map(deep_statement_refs(_, function_scope(function, in_scope)))
      |> list.flatten
    python.Match(subject, cases) ->
      list.append(
        expression_refs(subject, in_scope),
        list.flatten(
          list.map(cases, fn(match_case) { case_refs(match_case, in_scope) }),
        ),
      )
    python.While(condition, body) ->
      expression_refs(condition, in_scope)
      |> list.append(
        list.flatten(list.map(body, deep_statement_refs(_, in_scope))),
      )
  }
}

fn function_scope(
  function: python.Function,
  in_scope: set.Set(String),
) -> set.Set(String) {
  let parameter_names =
    list.map(function.parameters, fn(parameter) {
      case parameter {
        python.NameParam(name) -> [name]
        python.DiscardParam(_) -> []
      }
    })
    |> list.flatten
  set.from_list([function.name, ..parameter_names])
  |> set.union(in_scope)
}

// Binds anywhere in a statement tree, including inside nested function
// definitions, match case bodies and while loops. Used to detect assignments
// that shadow an enclosing scope's names, e.g. `values = ...` inside a case
// arm whose right hand side references the enclosing `values`.
fn all_nested_binds(statement: python.Statement) -> List(String) {
  case statement {
    python.FunctionDef(function) ->
      list.flatten(list.map(function.body, all_nested_binds))
    python.Match(_, cases) ->
      list.flatten(
        list.map(cases, fn(match_case) {
          list.flatten(list.map(match_case.body, all_nested_binds))
        }),
      )
    python.While(_, body) -> list.flatten(list.map(body, all_nested_binds))
    _ -> top_level_binds(statement)
  }
}

// The names bound by match case patterns and guards anywhere in a statement
// tree, including inside nested functions and while loops. Used to keep fresh
// names minted for module-shadowed parameters from colliding with case locals
// of the generated match functions.
fn all_case_binds(statement: python.Statement) -> List(String) {
  case statement {
    python.FunctionDef(function) ->
      list.flatten(list.map(function.body, all_case_binds))
    python.Match(_, cases) ->
      list.flatten(
        list.map(cases, fn(match_case) {
          let python.MatchCase(pattern, guard, body) = match_case
          let pattern_binds = pattern_binds(pattern)
          let guard_binds =
            option.unwrap(option.map(guard, expression_binds), [])
          let body_binds = list.flatten(list.map(body, all_case_binds))
          pattern_binds
          |> list.append(guard_binds)
          |> list.append(body_binds)
        }),
      )
    python.While(_, body) -> list.flatten(list.map(body, all_case_binds))
    _ -> []
  }
}

// Applies the block's renames inside a nested function definition, match or
// while loop, where program order determines whether a reference points at a
// renamed local or at the enclosing scope.
//
// Three renaming dicts are in play, each activated differently:
//   - `renames`        - block-level renames (a name bound at the top level of
//                        a function body that collides with a reference from
//                        the enclosing scope). Active when the name is in the
//                        accumulated program-order `scope`.
//   - `cross_renames`  - the enclosing match case's effective renames (names
//                        the enclosing case binds, which this scope references
//                        as closures over the renamed locals). Always active.
//   - `own_cross`      - the current match case's own renames (names it binds
//                        that collide with another arm's references). Active
//                        once the name is bound in this program-order walk
//                        (`cross_scope`), so a reference before the binding
//                        still points at the enclosing scope.
fn resolve_nested_binds(
  statement: python.Statement,
  renames: dict.Dict(String, String),
  cross_renames: dict.Dict(String, String),
  own_cross: dict.Dict(String, String),
  scope: set.Set(String),
  cross_scope: set.Set(String),
  bound: set.Set(String),
  pool: dict.Dict(String, Int),
) -> #(python.Statement, dict.Dict(String, Int)) {
  case statement {
    python.FunctionDef(function) -> {
      let renamed_function =
        python.Function(
          ..function,
          parameters: list.map(function.parameters, rename_function_parameter(
            _,
            renames,
          )),
        )
      // References inside the function body to the enclosing case's renamed
      // bindings are closures: the case's active renames become this scope's
      // always-active renames. The case's own renames are threaded through so
      // a rebind inside the function gets a fresh name (e.g. a `use` callback
      // destructuring the same name its enclosing case pattern bound).
      let effective =
        dict.merge(
          cross_renames,
          dict.filter(own_cross, fn(name, _) { set.contains(cross_scope, name) }),
        )
      let #(body, pool) =
        nested_resolve_fold(
          renamed_function.body,
          renames,
          effective,
          own_cross,
          set.union(
            function_scope(renamed_function, scope),
            set.from_list(function_parameter_names(function.parameters)),
          ),
          // A new function scope: its own binds activate the case renames,
          // but the enclosing case's binds do not.
          set.new(),
          bound,
          pool,
        )
      #(
        python.FunctionDef(python.Function(..renamed_function, body: body)),
        pool,
      )
    }
    python.Match(subject, cases) -> {
      let #(renamed_cases, pool) =
        resolve_match_cases(
          cases,
          renames,
          cross_renames,
          own_cross,
          scope,
          bound,
          pool,
        )
      #(
        python.Match(
          subject: rename_expression(subject, renames, scope),
          cases: renamed_cases,
        ),
        pool,
      )
    }
    python.While(condition, body) -> {
      let #(body, pool) =
        nested_resolve_fold(
          body,
          renames,
          cross_renames,
          own_cross,
          scope,
          cross_scope,
          bound,
          pool,
        )
      #(
        python.While(
          condition: rename_expression(condition, renames, scope),
          body: body,
        ),
        pool,
      )
    }
    _ -> #(statement, pool)
  }
}

// The names that are being renamed in this program-order walk right now: the
// block renames for names in scope (except the case's own, which are handled
// by the cross machinery), the enclosing case's renames for closures, and the
// current case's renames once its bindings are in scope.
fn active_renames_for(
  renames: dict.Dict(String, String),
  cross_renames: dict.Dict(String, String),
  own_cross: dict.Dict(String, String),
  scope: set.Set(String),
  cross_scope: set.Set(String),
) -> dict.Dict(String, String) {
  let cross_keys = set.from_list(dict.keys(own_cross))
  dict.merge(
    dict.merge(
      dict.filter(renames, fn(name, _) {
        set.contains(scope, name) && !set.contains(cross_keys, name)
      }),
      cross_renames,
    ),
    dict.filter(own_cross, fn(name, _) { set.contains(cross_scope, name) }),
  )
}

fn nested_resolve_fold(
  statements: List(python.Statement),
  renames: dict.Dict(String, String),
  cross_renames: dict.Dict(String, String),
  own_cross: dict.Dict(String, String),
  initial_scope: set.Set(String),
  initial_cross_scope: set.Set(String),
  initial_bound: set.Set(String),
  pool: dict.Dict(String, Int),
) -> #(List(python.Statement), dict.Dict(String, Int)) {
  let #(_, _, _, _, _, _, reversed, pool) =
    list.fold(
      statements,
      #(
        initial_scope,
        initial_cross_scope,
        initial_bound,
        renames,
        cross_renames,
        own_cross,
        [],
        pool,
      ),
      fn(acc, statement) {
        let #(
          scope,
          cross_scope,
          bound,
          renames,
          cross_renames,
          own_cross,
          out,
          pool,
        ) = acc
        let active_renames =
          active_renames_for(
            renames,
            cross_renames,
            own_cross,
            scope,
            cross_scope,
          )
        let #(renamed, pool) =
          statement
          |> rename_statement(active_renames, set.new(), pool)
        let #(renamed, renames, own_cross, pool) =
          rename_binding_targets(renamed, renames, own_cross, bound, pool)
        let #(renamed, pool) =
          resolve_nested_binds(
            renamed,
            renames,
            cross_renames,
            own_cross,
            scope,
            cross_scope,
            bound,
            pool,
          )
        let next_scope =
          set.union(scope, set.from_list(top_level_binds(statement)))
        let next_cross_scope =
          set.union(cross_scope, set.from_list(top_level_binds(statement)))
        let next_bound =
          set.union(bound, set.from_list(top_level_binds(statement)))
        #(
          next_scope,
          next_cross_scope,
          next_bound,
          renames,
          cross_renames,
          own_cross,
          [renamed, ..out],
          pool,
        )
      },
    )
  #(list.reverse(reversed), pool)
}

// Names a case pattern binds are locals of the generated match function;
// references to other renamed names in its body are closures over the
// enclosing scope's renamed locals, so they are renamed in program order.
// Body assignments that shadow an enclosing renamed name are handled by the
// program order fold (their binding targets are always renamed).
fn resolve_match_cases(
  cases: List(python.MatchCase),
  renames: dict.Dict(String, String),
  cross_renames: dict.Dict(String, String),
  own_cross: dict.Dict(String, String),
  scope: set.Set(String),
  bound: set.Set(String),
  pool: dict.Dict(String, Int),
) -> #(List(python.MatchCase), dict.Dict(String, Int)) {
  let all_binds =
    cases
    |> list.map(case_binds)
    |> list.flatten
  let all_refs =
    cases
    |> list.map(fn(match_case) { case_refs(match_case, set.new()) })
    |> list.flatten
  let used =
    set.from_list(all_binds)
    |> set.union(set.from_list(all_refs))
    |> set.union(set.from_list(dict.values(renames)))
    |> set.union(set.from_list(dict.values(cross_renames)))
  let collisions =
    all_binds
    |> list.filter(fn(name) {
      list.any(all_refs, fn(referenced) { referenced == name })
    })
    |> list.unique

  let #(new_cross, pool) =
    list.fold(collisions, #(dict.new(), pool), fn(acc, name) {
      let #(renames, pool) = acc
      let #(fresh, pool) = fresh_name(name, used, pool)
      #(dict.insert(renames, name, fresh), pool)
    })

  let #(renamed_cases, pool) =
    list.fold(cases, #([], pool), fn(acc, match_case) {
      let #(out, pool) = acc
      let #(renamed, pool) =
        nested_resolve_case(
          match_case,
          renames,
          cross_renames,
          own_cross,
          new_cross,
          scope,
          bound,
          pool,
        )
      #([renamed, ..out], pool)
    })

  #(list.reverse(renamed_cases), pool)
}

fn nested_resolve_case(
  match_case: python.MatchCase,
  renames: dict.Dict(String, String),
  cross_renames: dict.Dict(String, String),
  own_cross: dict.Dict(String, String),
  new_cross: dict.Dict(String, String),
  scope: set.Set(String),
  bound: set.Set(String),
  pool: dict.Dict(String, Int),
) -> #(python.MatchCase, dict.Dict(String, Int)) {
  let python.MatchCase(pattern, guard, body) = match_case
  let pattern_binds = pattern_binds(pattern)
  let guard_binds = option.unwrap(option.map(guard, expression_binds), [])
  let case_names = list.append(pattern_binds, guard_binds)
  // The names this case itself binds (pattern, guard, or body) that collide
  // with another arm's references are renamed within this case: its pattern,
  // guard, and the body references that come after the binding.
  let cross_local =
    dict.filter(new_cross, fn(name, _) {
      list.contains(case_binds(match_case), name)
    })
  // The enclosing case's renames are threaded through so a rebind inside
  // this case (e.g. a `use` callback destructuring a name the enclosing
  // case's pattern bound) still gets a fresh name, but names this case's
  // pattern binds shadow the enclosing scope for the whole body.
  let own_cross_local =
    dict.merge(
      dict.filter(own_cross, fn(name, _) { !list.contains(pattern_binds, name) }),
      cross_local,
    )
  // Names the case's pattern binds shadow the enclosing scope for the whole
  // body, so both the block renames and the enclosing case's renames for
  // those names must not apply.
  let local_renames =
    dict.filter(renames, fn(name, _) { !list.contains(pattern_binds, name) })
  let local_cross_renames =
    dict.filter(cross_renames, fn(name, _) {
      !list.contains(pattern_binds, name)
    })
  // The guard runs after the pattern binds, so references to the case's own
  // renamed pattern binds are renamed, but references to names the body binds
  // still point at the enclosing scope.
  let guard_renames =
    dict.merge(
      dict.merge(local_renames, local_cross_renames),
      dict.filter(new_cross, fn(name, _) { list.contains(case_names, name) }),
    )
  let initial_scope =
    scope
    |> set.union(set.from_list(pattern_binds))
    |> set.union(set.from_list(guard_binds))
  // Only the case's own bindings are in scope for its renames at the start of
  // its body: a reference that comes before the binding (e.g. in a nested
  // function in the binding's own right hand side) still points at the
  // enclosing scope.
  let initial_cross_scope =
    set.from_list(pattern_binds)
    |> set.union(set.from_list(guard_binds))
  let initial_bound =
    bound
    |> set.union(set.from_list(pattern_binds))
    |> set.union(set.from_list(guard_binds))
  let #(body, pool) =
    nested_resolve_fold(
      body,
      local_renames,
      local_cross_renames,
      own_cross_local,
      initial_scope,
      initial_cross_scope,
      initial_bound,
      pool,
    )
  let pattern = rename_pattern(pattern, cross_local)
  let guard = option.map(guard, rename_expression(_, guard_renames, set.new()))
  #(python.MatchCase(pattern, guard, body), pool)
}

fn rename_pattern(
  pattern: python.Pattern,
  renames: dict.Dict(String, String),
) -> python.Pattern {
  case pattern {
    python.PatternWildcard
    | python.PatternInt(_)
    | python.PatternFloat(_)
    | python.PatternString(_) -> pattern
    python.PatternVariable(name) ->
      python.PatternVariable(result.unwrap(dict.get(renames, name), name))
    python.PatternAssignment(inner, name) ->
      python.PatternAssignment(
        rename_pattern(inner, renames),
        result.unwrap(dict.get(renames, name), name),
      )
    python.PatternTuple(patterns) ->
      python.PatternTuple(list.map(patterns, rename_pattern(_, renames)))
    python.PatternList(elems, rest) ->
      python.PatternList(
        list.map(elems, rename_pattern(_, renames)),
        option.map(rest, rename_pattern(_, renames)),
      )
    python.PatternAlternate(patterns) ->
      python.PatternAlternate(list.map(patterns, rename_pattern(_, renames)))
    python.PatternConstructor(module, constructor, arguments) ->
      python.PatternConstructor(
        module,
        constructor,
        list.map(arguments, rename_pattern_field(_, renames)),
      )
  }
}

fn rename_pattern_field(
  field: python.Field(python.Pattern),
  renames: dict.Dict(String, String),
) -> python.Field(python.Pattern) {
  case field {
    python.LabelledField(label, item) ->
      python.LabelledField(label, rename_pattern(item, renames))
    python.UnlabelledField(item) ->
      python.UnlabelledField(rename_pattern(item, renames))
  }
}

// Renames a function parameter that collides with a renamed name.
fn rename_function_parameter(
  parameter: python.FunctionParameter,
  renames: dict.Dict(String, String),
) -> python.FunctionParameter {
  case parameter {
    python.NameParam(name) ->
      python.NameParam(result.unwrap(dict.get(renames, name), name))
    python.DiscardParam(_) -> parameter
  }
}

fn rename_statement(
  statement: python.Statement,
  renames: dict.Dict(String, String),
  in_scope: set.Set(String),
  pool: dict.Dict(String, Int),
) -> #(python.Statement, dict.Dict(String, Int)) {
  case statement {
    python.Expression(expression) -> #(
      python.Expression(rename_expression(expression, renames, in_scope)),
      pool,
    )
    python.Return(expression) -> #(
      python.Return(rename_expression(expression, renames, in_scope)),
      pool,
    )
    // Binding targets are handled by `rename_binding_targets` after this
    // call, which knows whether the name is already bound in this program
    // order walk (a rebind needing a fresh name) or not; renaming the target
    // here would hide the original name from that check.
    python.SimpleAssignment(name, value) -> #(
      python.SimpleAssignment(name, rename_expression(value, renames, in_scope)),
      pool,
    )
    python.MultipleAssignment(names, value) -> #(
      python.MultipleAssignment(
        names,
        rename_expression(value, renames, in_scope),
      ),
      pool,
    )
    // Nested function bodies are handled by `resolve_nested_binds` during the
    // program-order fold, which tracks whether a reference points at a renamed
    // enclosing local or at a binding inside the function itself. Renaming
    // here would apply the renames before a rebind inside the function has
    // been given its fresh name.
    python.FunctionDef(_) -> #(statement, pool)
    python.Match(subject, cases) -> #(
      python.Match(rename_expression(subject, renames, in_scope), cases),
      pool,
    )
    python.While(condition, body) -> {
      let #(body, pool) =
        list.fold(body, #([], pool), fn(acc, statement) {
          let #(out, pool) = acc
          let #(renamed, pool) =
            rename_statement(statement, renames, in_scope, pool)
          #([renamed, ..out], pool)
        })
      #(
        python.While(
          rename_expression(condition, renames, in_scope),
          list.reverse(body),
        ),
        pool,
      )
    }
  }
}

fn rename_expression(
  expression: python.Expression,
  renames: dict.Dict(String, String),
  in_scope: set.Set(String),
) -> python.Expression {
  case expression {
    python.Variable(name) ->
      case set.contains(in_scope, name) {
        True -> expression
        False -> python.Variable(result.unwrap(dict.get(renames, name), name))
      }
    python.String(_) | python.Number(_) | python.Bool(_) | python.Nil ->
      expression
    python.ModuleRef(_) -> expression
    python.Tuple(elements) ->
      python.Tuple(list.map(elements, rename_expression(_, renames, in_scope)))
    python.Negate(inner) ->
      python.Negate(rename_expression(inner, renames, in_scope))
    python.Not(inner) -> python.Not(rename_expression(inner, renames, in_scope))
    python.Panic(inner) ->
      python.Panic(rename_expression(inner, renames, in_scope))
    python.Todo(inner) ->
      python.Todo(rename_expression(inner, renames, in_scope))
    python.Lambda(args, body) -> {
      let renamed_args =
        list.map(args, fn(arg) {
          case arg {
            python.Variable(name) ->
              python.Variable(result.unwrap(dict.get(renames, name), name))
            _ -> arg
          }
        })
      python.Lambda(
        renamed_args,
        rename_expression(
          body,
          renames,
          set.union(in_scope, set.from_list(lambda_param_names(renamed_args))),
        ),
      )
    }
    python.List(elements) ->
      python.List(list.map(elements, rename_expression(_, renames, in_scope)))
    python.ListWithRest(elements, rest) ->
      python.ListWithRest(
        list.map(elements, rename_expression(_, renames, in_scope)),
        rename_expression(rest, renames, in_scope),
      )
    python.TupleIndex(tuple, index) ->
      python.TupleIndex(rename_expression(tuple, renames, in_scope), index)
    python.FieldAccess(container, label) ->
      python.FieldAccess(rename_expression(container, renames, in_scope), label)
    python.Call(function, arguments) ->
      python.Call(
        rename_expression(function, renames, in_scope),
        list.map(arguments, rename_expression_field(_, renames, in_scope)),
      )
    python.RecordUpdate(record, fields) ->
      python.RecordUpdate(
        rename_expression(record, renames, in_scope),
        list.map(fields, rename_expression_field(_, renames, in_scope)),
      )
    python.BinaryOperator(name, left, right) ->
      python.BinaryOperator(
        name,
        rename_expression(left, renames, in_scope),
        rename_expression(right, renames, in_scope),
      )
    python.Slice(container, start, end) ->
      python.Slice(
        rename_expression(container, renames, in_scope),
        rename_expression(start, renames, in_scope),
        option.map(end, rename_expression(_, renames, in_scope)),
      )
    python.AssignmentExpression(name, value) ->
      python.AssignmentExpression(
        result.unwrap(dict.get(renames, name), name),
        rename_expression(value, renames, in_scope),
      )
    python.IsNotNone(inner) ->
      python.IsNotNone(rename_expression(inner, renames, in_scope))
    python.BitString(segments) ->
      python.BitString(
        list.map(segments, fn(segment) {
          let python.BitStringSegment(value, options) = segment
          python.BitStringSegment(
            rename_expression(value, renames, in_scope),
            options,
          )
        }),
      )
  }
}

fn rename_expression_field(
  field: python.Field(python.Expression),
  renames: dict.Dict(String, String),
  in_scope: set.Set(String),
) -> python.Field(python.Expression) {
  case field {
    python.LabelledField(label, item) ->
      python.LabelledField(label, rename_expression(item, renames, in_scope))
    python.UnlabelledField(item) ->
      python.UnlabelledField(rename_expression(item, renames, in_scope))
  }
}

// Python has no tail-call optimization, so a Gleam function that recurses in
// tail position (like `drop_comments` in tom.gleam, which recurses once per
// input token) overflows the C stack with a RecursionError. To fix this we
// rewrite direct self-recursive tail calls into a `while True:` loop.
//
//     def drop_comments(input, acc, state):
//         while True:
//             def _fn_case_0(_case_subject):
//                 match _case_subject:
//                     case GleamList(g, input):
//                         return _Tco((input, to_gleam_list([g], acc), state))
//                     case None:
//                         return list.reverse(acc)
//             _result = _fn_case_0(input)
//             match isinstance(_result, _Tco):
//                 case True:
//                     input, acc, state = _result.args
//                 case False:
//                     return _result
//
// The `_Tco` marker propagates up through any nested `_fn_def_N`/`_fn_case_N`
// driver functions (they just pass it through their return chain) until it
// reaches the top-level loop, which unpacks it into the function's parameters
// and starts the next iteration.
pub fn resolve_tail_calls(
  statements: List(python.Statement),
  function_name: String,
  parameters: List(python.FunctionParameter),
) -> List(python.Statement) {
  case statement_has_tail_call(statements, function_name) {
    False -> statements
    True -> {
      let rewritten = rewrite_statements_tail(statements, function_name)
      // The driver expression is the value the tail call is replaced by. For
      // a direct tail call it is `driver(subject)`; when the tail call is
      // nested (e.g. inside a `use` callback, which commonly recurses), it is
      // the last statement's expression, which the callback's GleamTco
      // propagates through. The extraction uses the pre-rewrite statements so
      // a GleamTco marker is never mistaken for the driver.
      let driver_expression = case list.reverse(statements) {
        [
          python.Return(python.Call(
            python.Variable(driver_name),
            [python.UnlabelledField(subject)],
          )),
          ..
        ] ->
          option.Some(
            python.Call(python.Variable(driver_name), [
              python.UnlabelledField(subject),
            ]),
          )
        [python.Return(expression), ..] -> option.Some(expression)
        _ -> option.None
      }
      case driver_expression {
        option.Some(driver_call) -> {
          let loop_body =
            case list.reverse(rewritten) {
              [python.Return(_), ..rest] -> list.reverse(rest)
              _ -> rewritten
            }
            |> list.append([
              python.SimpleAssignment("_result", driver_call),
              python.Match(
                subject: python.Call(python.Variable("isinstance"), [
                  python.UnlabelledField(python.Variable("_result")),
                  python.UnlabelledField(python.Variable("GleamTco")),
                ]),
                cases: [
                  python.MatchCase(
                    python.PatternConstructor(option.None, "True", []),
                    option.None,
                    [unpack_result(parameters)],
                  ),
                  python.MatchCase(
                    python.PatternConstructor(option.None, "False", []),
                    option.None,
                    [python.Return(python.Variable("_result"))],
                  ),
                ],
              ),
            ])
          [python.While(python.Bool("True"), loop_body)]
        }
        option.None -> rewritten
      }
    }
  }
}

fn parameter_names(parameters: List(python.FunctionParameter)) -> List(String) {
  list.map(parameters, fn(parameter) {
    case parameter {
      python.NameParam(name) -> name
      python.DiscardParam(index) ->
        case index {
          0 -> "_"
          _ -> "_" <> int.to_string(index)
        }
    }
  })
}

// Reassigns the function's parameters from the `_Tco` result. With a single
// parameter the tuple must be unpacked with an index, since `n = args` would
// assign the whole tuple.
fn unpack_result(
  parameters: List(python.FunctionParameter),
) -> python.Statement {
  let names = parameter_names(parameters)
  case names {
    [single] ->
      python.SimpleAssignment(
        single,
        python.TupleIndex(
          python.FieldAccess(python.Variable("_result"), "args"),
          0,
        ),
      )
    multiple ->
      python.MultipleAssignment(
        multiple,
        python.FieldAccess(python.Variable("_result"), "args"),
      )
  }
}

fn statement_has_tail_call(
  statements: List(python.Statement),
  function_name: String,
) -> Bool {
  case statements {
    [] -> False
    [statement, ..rest] ->
      case statement {
        python.FunctionDef(function) ->
          // Only descend into nested functions that are invoked in tail
          // position of this function (the case/match driver chain). Nested
          // value-helper functions (e.g. an inline case inside a larger
          // expression) are not part of the recursion, and rewriting their
          // self-calls would corrupt the values they return.
          function_is_tail_driver(function.name, statements)
          && statement_has_tail_call(function.body, function_name)
          || statement_has_tail_call(rest, function_name)
        python.Match(_, cases) ->
          match_cases_has_tail_call(cases, function_name)
          || statement_has_tail_call(rest, function_name)
        python.Return(expression) ->
          is_tail_call(expression, function_name)
          || statement_has_tail_call(rest, function_name)
        _ -> statement_has_tail_call(rest, function_name)
      }
  }
}

fn match_cases_has_tail_call(
  cases: List(python.MatchCase),
  function_name: String,
) -> Bool {
  case cases {
    [] -> False
    [match_case, ..rest] ->
      case match_case {
        python.MatchCase(_, _, body) ->
          statement_has_tail_call(body, function_name)
          || match_cases_has_tail_call(rest, function_name)
      }
  }
}

// Whether the tail of the statements invokes the named nested function either
// directly as the call target or as a callback argument. Nested functions are
// only safe to rewrite when the `GleamTco` marker they return can flow back to
// the enclosing driver: that requires the callee to hand the callback's value
// through unchanged (e.g. `result.try`, `result.map`, a local `do` helper).
// Functions that consume the callback's result with their own match protocol
// (`list.any`, `list.map`, `list.fold`) would swallow the marker, so the
// helpers that recurse through them (`statement_has_tail_call`,
// `rewrite_statements_tail`) are written with direct recursion instead.
fn function_is_tail_driver(
  name: String,
  statements: List(python.Statement),
) -> Bool {
  list.any(statements, fn(statement) {
    case statement {
      python.Return(expression) -> expression_passes_function(expression, name)
      _ -> False
    }
  })
}

fn expression_passes_function(
  expression: python.Expression,
  name: String,
) -> Bool {
  case expression {
    python.Call(python.Variable(callee), _) if callee == name -> True
    python.Call(_, arguments) ->
      list.any(arguments, fn(field) {
        case field {
          python.UnlabelledField(python.Variable(arg_name))
            if arg_name == name
          -> True
          python.LabelledField(_, python.Variable(arg_name))
            if arg_name == name
          -> True
          _ -> False
        }
      })
    _ -> False
  }
}

fn is_tail_call(expression: python.Expression, function_name: String) -> Bool {
  case expression {
    python.Call(python.Variable(name), _) if name == function_name -> True
    _ -> False
  }
}

fn rewrite_statements_tail(
  statements: List(python.Statement),
  function_name: String,
) -> List(python.Statement) {
  case statements {
    [] -> []
    [statement, ..rest] -> [
      rewrite_statement_tail(statement, statements, function_name),
      ..rewrite_statements_tail(rest, function_name)
    ]
  }
}

fn rewrite_statement_tail(
  statement: python.Statement,
  statements: List(python.Statement),
  function_name: String,
) -> python.Statement {
  case statement {
    python.FunctionDef(function) ->
      case function_is_tail_driver(function.name, statements) {
        True ->
          python.FunctionDef(
            python.Function(
              ..function,
              body: rewrite_statements_tail(function.body, function_name),
            ),
          )
        False -> statement
      }
    python.Match(subject, cases) ->
      python.Match(
        subject: subject,
        cases: list.map(cases, fn(match_case) {
          let python.MatchCase(pattern, guard, body) = match_case
          python.MatchCase(
            pattern,
            guard,
            rewrite_statements_tail(body, function_name),
          )
        }),
      )
    python.Return(expression) ->
      python.Return(rewrite_expression_tail(expression, function_name))
    _ -> statement
  }
}

fn rewrite_expression_tail(
  expression: python.Expression,
  function_name: String,
) -> python.Expression {
  case expression {
    python.Call(python.Variable(name), arguments) if name == function_name ->
      python.Call(python.Variable("GleamTco"), [
        python.UnlabelledField(
          python.Tuple(
            list.map(arguments, fn(field) {
              case field {
                python.UnlabelledField(item) -> item
                python.LabelledField(_, item) -> item
              }
            }),
          ),
        ),
      ])
    _ -> expression
  }
}
