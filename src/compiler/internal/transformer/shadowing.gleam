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
      // Deep refs: a reference to an enclosing scope's name inside a match
      // case body or nested function still resolves to the (unbound) local
      // in Python, so it must count as a collision. Only top-level binds of
      // this block are considered: binds inside case bodies and nested
      // functions are resolved by their own shadowing passes (the case
      // machinery, closure resolution), so a name the case arm rebinds must
      // not trigger a rename of the enclosing scope's binding here. A name
      // already bound by an earlier top-level statement is a legitimate
      // capture: references to it from a later closure do not collide.
      let binds_so_far = set.difference(scope, initial_scope)
      let more_refs = deep_statement_refs(statement, scope, binds_so_far)
      let more_binds = top_level_binds(statement)
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
              |> rename_statement(active_renames, set.new(), bound, pool)
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
    python.If(condition, body) -> {
      let #(renamed_body, pool) =
        rename_module_shadowed(body, renaming, used, pool)
      #(
        python.If(
          rename_expression(condition, renaming, set.new()),
          renamed_body,
        ),
        renaming,
        pool,
      )
    }
    python.For(targets, iterable, body) -> {
      let #(renamed_body, pool) =
        rename_module_shadowed(body, renaming, used, pool)
      #(
        python.For(
          targets,
          rename_expression(iterable, renaming, set.new()),
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
    | python.While(_, _)
    | python.If(_, _)
    | python.For(_, _, _) -> []
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
    | python.While(_, _)
    | python.If(_, _)
    | python.For(_, _, _) -> #(statement, renames, own_cross, pool)
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
      let more_refs =
        deep_statement_refs(
          statement,
          scope,
          set.difference(scope, initial_scope),
        )
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
    python.Dict(entries) ->
      list.flatten(
        list.map(entries, fn(entry) {
          let #(_, value) = entry
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
    python.Dict(entries) ->
      list.flatten(
        list.map(entries, fn(entry) {
          let #(_, value) = entry
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
    python.If(_, body) -> list.flatten(list.map(body, statement_binds))
    python.For(_, _, body) -> list.flatten(list.map(body, statement_binds))
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
    python.If(condition, body) ->
      expression_refs(condition, in_scope)
      |> list.append(list.flatten(list.map(body, statement_refs(_, in_scope))))
    python.For(_, iterable, body) ->
      expression_refs(iterable, in_scope)
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
  binds_so_far: set.Set(String),
) -> List(String) {
  case statement {
    python.Expression(expression) | python.Return(expression) ->
      expression_refs(expression, in_scope)
    python.SimpleAssignment(_, value) -> expression_refs(value, in_scope)
    python.MultipleAssignment(_, value) -> expression_refs(value, in_scope)
    python.FunctionDef(function) ->
      // Track binds in program order so a reference to a name the nested
      // function binds itself is not mistaken for a reference to the
      // enclosing scope. Only the function's own name and parameters are in
      // scope here: a reference to an enclosing-scope name (e.g. a parameter
      // of the enclosing function captured by the closure) must still be
      // reported, because a later rebind of that name in the enclosing block
      // would break the closure's capture (Python closures capture by name).
      // A name already bound by an earlier top-level statement is a
      // legitimate capture (the closure was defined after the bind), so it is
      // not reported.
      body_refs_in_order(function.body, function_own_scope(function))
      |> list.filter(fn(name) { !set.contains(binds_so_far, name) })
    python.Match(subject, cases) ->
      list.append(
        expression_refs(subject, in_scope),
        list.flatten(
          list.map(cases, fn(match_case) { case_refs(match_case, in_scope) }),
        ),
      )
    python.While(condition, body) ->
      expression_refs(condition, in_scope)
      |> list.append(body_refs_in_order(body, in_scope))
    python.If(condition, body) ->
      expression_refs(condition, in_scope)
      |> list.append(body_refs_in_order(body, in_scope))
    python.For(_, iterable, body) ->
      expression_refs(iterable, in_scope)
      |> list.append(body_refs_in_order(body, in_scope))
  }
}

fn function_scope(
  function: python.Function,
  in_scope: set.Set(String),
) -> set.Set(String) {
  function_own_scope(function)
  |> set.union(in_scope)
}

// The names a function binds itself: its own name and its parameters.
fn function_own_scope(function: python.Function) -> set.Set(String) {
  let parameter_names =
    list.map(function.parameters, fn(parameter) {
      case parameter {
        python.NameParam(name) -> [name]
        python.DiscardParam(_) -> []
      }
    })
    |> list.flatten
  set.from_list([function.name, ..parameter_names])
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
    python.If(_, body) -> list.flatten(list.map(body, all_nested_binds))
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
    python.If(_, body) -> list.flatten(list.map(body, all_case_binds))
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
      // A closure captures the enclosing scope's bindings that are in scope at
      // its definition point. A rename for a name the enclosing block binds
      // LATER than this closure (e.g. `let fun = fn() { fun }` rebinding a
      // parameter the closure body references) must not apply here: the
      // closure's reference points at the earlier binding (the parameter), so
      // it keeps the original name; only references after the binding use the
      // fresh name. Names already bound by earlier statements of the enclosing
      // block (`bound`) are captured and use their rename.
      let block_renames =
        dict.filter(renames, fn(name, _) { set.contains(bound, name) })
      // A parameter must be renamed with exactly the renames the body's
      // references are renamed with (`block_renames`): the parameter shadows
      // any enclosing binding of the same name for the whole body, so its
      // references point at the parameter and are renamed by the body fold. A
      // rename for a name the block binds LATER than this closure renames the
      // parameter but not the body's references to it, breaking them.
      let renamed_function =
        python.Function(
          ..function,
          parameters: list.map(function.parameters, rename_function_parameter(
            _,
            block_renames,
          )),
        )
      // References inside the function body to the enclosing case's renamed
      // bindings are closures: the case's active renames become this scope's
      // always-active renames. The case's own renames are threaded through so
      // a rebind inside the function gets a fresh name (e.g. a `use` callback
      // destructuring the same name its enclosing case pattern bound). But a
      // name the function's own parameters bind is NOT a closure: it points at
      // the parameter for the whole body, so the enclosing case's renames for
      // those names must not apply inside.
      let function_binds =
        set.from_list(function_parameter_names(function.parameters))
      let effective =
        dict.merge(
          cross_renames,
          dict.filter(own_cross, fn(name, _) { set.contains(cross_scope, name) }),
        )
        |> dict.filter(fn(name, _) { !set.contains(function_binds, name) })
      let #(body, pool) =
        nested_resolve_fold(
          renamed_function.body,
          block_renames,
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
      // The subject is evaluated in program order at this statement's position,
      // so it references the bindings in scope now (the parameters/earlier
      // binds). A rename for a name this block binds LATER (e.g. `let times =
      // times / 2` after a `case times` subject) must not apply here: only
      // names already bound (`bound`) use their rename.
      let subject_renames =
        dict.filter(renames, fn(name, _) { set.contains(bound, name) })
      #(
        python.Match(
          subject: rename_expression(subject, subject_renames, scope),
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
      // The condition runs in program order before the loop body's binds; only
      // names bound by earlier statements use their rename here.
      let condition_renames =
        dict.filter(renames, fn(name, _) { set.contains(bound, name) })
      #(
        python.While(
          condition: rename_expression(condition, condition_renames, scope),
          body: body,
        ),
        pool,
      )
    }
    python.If(condition, body) -> {
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
      // The condition runs in program order before the branch's binds; only
      // names bound by earlier statements use their rename here.
      let condition_renames =
        dict.filter(renames, fn(name, _) { set.contains(bound, name) })
      #(
        python.If(
          condition: rename_expression(condition, condition_renames, scope),
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
        let in_cross_scope = set.contains(cross_scope, name)
        let active_cross = set.contains(cross_keys, name) && in_cross_scope
        set.contains(scope, name) && !active_cross
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
          |> rename_statement(active_renames, set.new(), bound, pool)
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
  let all_guard_binds =
    cases
    |> list.map(fn(match_case) {
      let python.MatchCase(_, guard, _) = match_case
      option.unwrap(option.map(guard, expression_binds), [])
    })
    |> list.flatten
  // `nested_resolve_case` renames the case bodies through the renames dicts
  // when it resolves them, so a reference's FINAL name is what matters for
  // collision detection: a capture renamed to a fresh name here must not
  // collide with a reference that the enclosing renames will later rename to
  // that same fresh name. The precedence matches `active_renames_for`.
  let effective_rename = fn(name) {
    case dict.has_key(own_cross, name) {
      True -> result.unwrap(dict.get(own_cross, name), name)
      False ->
        case dict.has_key(cross_renames, name) {
          True -> result.unwrap(dict.get(cross_renames, name), name)
          False -> result.unwrap(dict.get(renames, name), name)
        }
    }
  }
  let all_refs =
    cases
    |> list.map(fn(match_case) { case_refs(match_case, set.new()) })
    |> list.flatten
  let final_refs = list.map(all_refs, effective_rename)
  let used =
    set.from_list(all_binds)
    |> set.union(set.from_list(final_refs))
    |> set.union(set.from_list(dict.values(renames)))
    |> set.union(set.from_list(dict.values(cross_renames)))
    |> set.union(set.from_list(dict.values(own_cross)))
    // Fresh names minted here become locals of the generated match function,
    // so they must not collide with names bound by nested functions or nested
    // matches inside the case bodies. A `use` callback that rebinds a name the
    // case pattern binds already renamed that rebind to a fresh name in its own
    // block-shadowing pass; if the pattern's cross rename minted the same fresh
    // name, the callback's pre-binding RHS reference would resolve to the local
    // instead of the pattern.
    |> set.union(set.from_list(
      cases
      |> list.map(fn(match_case) {
        list.flatten(list.map(match_case.body, all_nested_binds))
      })
      |> list.flatten,
    ))
    |> set.union(set.from_list(
      cases
      |> list.map(fn(match_case) {
        list.flatten(list.map(match_case.body, all_case_binds))
      })
      |> list.flatten,
    ))
  let collisions =
    all_binds
    |> list.filter(fn(name) {
      // A body bind's collision is detected against the raw reference name:
      // the block-level shadowing pass has already renamed body binds that
      // collide with an enclosing scope's references, so a final-name match
      // here would double-rename them. A guard bind (e.g. the walrus in a
      // string-concatenation pattern) is renamed through the guard renames,
      // whose effective names can differ from the raw name, so those compare
      // their final name against the final references.
      let matches_raw =
        list.any(final_refs, fn(referenced) { referenced == name })
      case list.contains(all_guard_binds, name) {
        False -> matches_raw
        True ->
          matches_raw
          || list.any(final_refs, fn(referenced) {
            referenced == effective_rename(name)
          })
      }
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
  bound: set.Set(String),
  pool: dict.Dict(String, Int),
) -> #(python.Statement, dict.Dict(String, Int)) {
  // At this statement's position in program order, only names bound by earlier
  // statements of the block use their rename. A rename for a name this block
  // binds LATER (e.g. `let times = times / 2` after a `case times % 2`
  // subject) must not apply to expressions evaluated now: they reference the
  // value bound before this statement (a parameter or an earlier `let`).
  let current_renames =
    dict.filter(renames, fn(name, _) { set.contains(bound, name) })
  case statement {
    python.Expression(expression) -> #(
      python.Expression(rename_expression(expression, current_renames, in_scope)),
      pool,
    )
    python.Return(expression) -> #(
      python.Return(rename_expression(expression, current_renames, in_scope)),
      pool,
    )
    // The right-hand side is evaluated before this statement binds its target,
    // so a reference to the target name points at the value bound before it (a
    // parameter, or a name an earlier statement bound). Names bound by earlier
    // statements use their rename (`current_renames`); the target's own fresh
    // name only applies from the statement after this one.
    python.SimpleAssignment(name, value) -> #(
      python.SimpleAssignment(
        name,
        rename_expression(value, current_renames, in_scope),
      ),
      pool,
    )
    python.MultipleAssignment(names, value) -> #(
      python.MultipleAssignment(
        names,
        rename_expression(value, current_renames, in_scope),
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
      python.Match(rename_expression(subject, current_renames, in_scope), cases),
      pool,
    )
    python.While(condition, body) -> {
      let #(body, pool) =
        list.fold(body, #([], pool), fn(acc, statement) {
          let #(out, pool) = acc
          let #(renamed, pool) =
            rename_statement(statement, renames, in_scope, set.new(), pool)
          #([renamed, ..out], pool)
        })
      #(
        python.While(
          rename_expression(condition, current_renames, in_scope),
          list.reverse(body),
        ),
        pool,
      )
    }
    python.For(targets, iterable, body) -> {
      let #(body, pool) =
        list.fold(body, #([], pool), fn(acc, statement) {
          let #(out, pool) = acc
          let #(renamed, pool) =
            rename_statement(statement, renames, in_scope, set.new(), pool)
          #([renamed, ..out], pool)
        })
      #(
        python.For(
          targets,
          rename_expression(iterable, current_renames, in_scope),
          list.reverse(body),
        ),
        pool,
      )
    }
    python.If(condition, body) -> {
      let #(body, pool) =
        list.fold(body, #([], pool), fn(acc, statement) {
          let #(out, pool) = acc
          let #(renamed, pool) =
            rename_statement(statement, renames, in_scope, set.new(), pool)
          #([renamed, ..out], pool)
        })
      #(
        python.If(
          rename_expression(condition, current_renames, in_scope),
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
    python.Dict(entries) ->
      python.Dict(
        list.map(entries, fn(entry) {
          let #(key, value) = entry
          #(key, rename_expression(value, renames, in_scope))
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
//         def _fn_case_0(_case_subject):
//             match _case_subject:
//                 case GleamList(g, input):
//                     return _Tco((input, to_gleam_list([g], acc), state))
//                 case None:
//                     return list.reverse(acc)
//         while True:
//             _result = _fn_case_0(input)
//             match isinstance(_result, _Tco):
//                 case True:
//                     input, acc, state = _result.args
//                 case False:
//                     return _result
//
// The driver closures are hoisted above the loop: recreating them on every
// iteration is pure overhead (each `def` re-allocates a closure object), and
// they only bind names, so moving them out is behaviour-preserving.
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
        option.Some(driver_call) ->
          // Inline the driver's match directly into the loop when the tail
          // call is a simple `driver(subject)`: the loop body becomes the
          // driver's own `match subject:`, a `return GleamTco((...))` case
          // becomes a direct parameter rebinding, and a value return ends the
          // loop. This avoids the per-iteration closure call, `GleamTco`
          // allocation, and `isinstance` dispatch.
          case inline_driver(driver_call, rewritten, parameters) {
            option.Some(inlined) -> inlined
            option.None -> {
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
                        unpack_result(parameters),
                      ),
                      python.MatchCase(
                        python.PatternConstructor(option.None, "False", []),
                        option.None,
                        [python.Return(python.Variable("_result"))],
                      ),
                    ],
                  ),
                ])
              let #(drivers, body) =
                list.partition(loop_body, fn(statement) {
                  case statement {
                    python.FunctionDef(_) -> True
                    _ -> False
                  }
                })
              list.append(drivers, [python.While(python.Bool("True"), body)])
            }
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

// Where a driver's result flows when its call is inlined. `Return` means the
// driver is called in tail position: a `return GleamTco((args))` case loops by
// rebinding the function's parameters and a value return ends the loop.
// `Assign(target)` means the driver's value is stored in `target` (e.g. a
// nested `case` whose result feeds a later tail call). `Other` marks a call
// site that cannot be inlined, so the driver is left as a closure.
type DriverPosition {
  DriverPositionReturn
  DriverPositionAssign(target: String)
  DriverPositionOther
}

// Inlines a `driver(subject)` tail call into a `while True` loop whose body is
// the driver's own `match`. The driver is a `_fn_case_N` closure whose body is
// a single `match` on the subject; a recursive case returns
// `GleamTco((new_args))` (rewritten by `rewrite_expression_tail`) and a value
// case returns the final value. Case bodies that recurse through their own
// nested `_fn_case_N` driver (e.g. `list.try_fold`, which tail-recurses inside
// an inner `case` on the fold function's result) are flattened too: the nested
// driver is inlined into the case body, so a `GleamTco` return there becomes a
// direct parameter rebinding. Returns `None` when the driver is not of this
// shape (e.g. the loop body has other statements the driver captures, its match
// body is missing, or a case does something other than `return GleamTco(...)`,
// `return value`, or a nested driver call), in which case the caller falls back
// to the `GleamTco`/`isinstance` protocol.
fn inline_driver(
  driver_call: python.Expression,
  rewritten: List(python.Statement),
  parameters: List(python.FunctionParameter),
) -> option.Option(List(python.Statement)) {
  case driver_call {
    python.Call(python.Variable(name), [python.UnlabelledField(subject)]) ->
      case rewritten {
        // The whole loop body is just the driver definition and its tail call.
        // If anything else is present (helper definitions, per-iteration
        // computations the driver captures via closure), inlining is not
        // valid, so fall back to the `GleamTco` protocol.
        [python.FunctionDef(function), python.Return(_)]
          if function.name == name
        -> inline_driver_function(function, subject, parameters)
        _ -> option.None
      }
    _ -> option.None
  }
}

fn inline_driver_function(
  function: python.Function,
  subject: python.Expression,
  parameters: List(python.FunctionParameter),
) -> option.Option(List(python.Statement)) {
  case function.body {
    [python.Match(match_subject, cases)] ->
      case inline_driver_cases(cases, parameters, DriverPositionReturn) {
        option.Some(inlined_cases) ->
          option.Some([
            python.While(
              python.Bool("True"),
              inline_match_statements(match_subject, subject, inlined_cases),
            ),
          ])
        option.None -> option.None
      }
    _ -> option.None
  }
}

// Builds the `match` that replaces an inlined driver's definition and call.
// The driver's match is on its own parameter (e.g. `_case_subject`), which case
// guards reference. When nothing references the subject, match on the subject
// expression directly; otherwise bind the subject to the parameter name first
// so guards still see it.
fn inline_match_statements(
  match_subject: python.Expression,
  subject: python.Expression,
  inlined_cases: List(python.MatchCase),
) -> List(python.Statement) {
  case match_subject {
    python.Variable(subject_name) ->
      case subject {
        // Complex subjects (a `dict.get` call, for example) are bound to the
        // driver parameter first so the match dispatches on a simple variable
        // and the generator can emit a `type(x) is T` chain rather than a
        // match statement. A simple subject is matched directly.
        python.Variable(_) | python.FieldAccess(_, _) ->
          case subject_referenced(inlined_cases, subject_name) {
            True -> [
              python.SimpleAssignment(subject_name, subject),
              python.Match(subject: match_subject, cases: inlined_cases),
            ]
            False -> [python.Match(subject: subject, cases: inlined_cases)]
          }
        _ -> [
          python.SimpleAssignment(subject_name, subject),
          python.Match(subject: match_subject, cases: inlined_cases),
        ]
      }
    _ -> [python.Match(subject: subject, cases: inlined_cases)]
  }
}

// Whether any case guard or body references the driver's subject parameter
// (e.g. a `case _ if subject.startswith(...)` guard). Only then must the
// subject be bound to that name in the inlined loop.
fn subject_referenced(cases: List(python.MatchCase), name: String) -> Bool {
  list.any(cases, fn(match_case) {
    let python.MatchCase(_, guard, body) = match_case
    let guard_references = case guard {
      option.Some(expression) -> expression_references(expression, name)
      option.None -> False
    }
    guard_references
    || list.any(body, fn(statement) { statement_references(statement, name) })
  })
}

fn statement_references(statement: python.Statement, name: String) -> Bool {
  case statement {
    python.Expression(expression) -> expression_references(expression, name)
    python.Return(expression) -> expression_references(expression, name)
    python.SimpleAssignment(_, value) -> expression_references(value, name)
    python.MultipleAssignment(_, value) -> expression_references(value, name)
    python.Match(subject, cases) ->
      expression_references(subject, name)
      || list.any(cases, fn(match_case) {
        let python.MatchCase(_, guard, body) = match_case
        let guard_references = case guard {
          option.Some(expression) -> expression_references(expression, name)
          option.None -> False
        }
        guard_references
        || list.any(body, fn(s) { statement_references(s, name) })
      })
    python.While(_, body) ->
      list.any(body, fn(s) { statement_references(s, name) })
    python.If(_, body) ->
      list.any(body, fn(s) { statement_references(s, name) })
    python.For(_, _, body) ->
      list.any(body, fn(s) { statement_references(s, name) })
    python.FunctionDef(_) -> False
  }
}

fn expression_references(expression: python.Expression, name: String) -> Bool {
  case expression {
    python.Variable(value) -> value == name
    python.String(_) -> False
    python.Number(_) -> False
    python.Bool(_) -> False
    python.Nil -> False
    python.ModuleRef(_) -> False
    python.Tuple(elements) ->
      list.any(elements, fn(e) { expression_references(e, name) })
    python.Negate(e) -> expression_references(e, name)
    python.Not(e) -> expression_references(e, name)
    python.Panic(e) -> expression_references(e, name)
    python.Todo(e) -> expression_references(e, name)
    python.Lambda(_, body) -> expression_references(body, name)
    python.List(elements) ->
      list.any(elements, fn(e) { expression_references(e, name) })
    python.ListWithRest(elements, rest) ->
      list.any(elements, fn(e) { expression_references(e, name) })
      || expression_references(rest, name)
    python.TupleIndex(tuple, _) -> expression_references(tuple, name)
    python.FieldAccess(container, _) -> expression_references(container, name)
    python.Call(function, arguments) ->
      expression_references(function, name)
      || list.any(arguments, fn(field) {
        case field {
          python.UnlabelledField(item) -> expression_references(item, name)
          python.LabelledField(_, item) -> expression_references(item, name)
        }
      })
    python.RecordUpdate(record, fields) ->
      expression_references(record, name)
      || list.any(fields, fn(field) {
        case field {
          python.UnlabelledField(item) -> expression_references(item, name)
          python.LabelledField(_, item) -> expression_references(item, name)
        }
      })
    python.BinaryOperator(_, left, right) ->
      expression_references(left, name) || expression_references(right, name)
    python.Slice(container, start, end) ->
      expression_references(container, name)
      || expression_references(start, name)
      || {
        case end {
          option.Some(e) -> expression_references(e, name)
          option.None -> False
        }
      }
    python.AssignmentExpression(_, value) -> expression_references(value, name)
    python.IsNotNone(e) -> expression_references(e, name)
    python.BitString(_) -> False
    python.Dict(_) -> False
  }
}

// Rewrites each case of the driver's match into loop-body form. Every case
// body goes through `inline_case_body` with the given position, so a
// `return GleamTco((args))` tail becomes a parameter rebinding, a value return
// ends the loop, and a case body that recurses through its own nested driver
// is flattened recursively. Any case that cannot be inlined makes the whole
// driver non-inlinable.
fn inline_driver_cases(
  cases: List(python.MatchCase),
  parameters: List(python.FunctionParameter),
  position: DriverPosition,
) -> option.Option(List(python.MatchCase)) {
  list.fold(cases, option.Some([]), fn(acc, match_case) {
    case acc {
      option.None -> option.None
      option.Some(inlined) ->
        case inline_case_body(match_case.body, parameters, position) {
          option.Some(new_body) ->
            option.Some(
              list.append(inlined, [
                python.MatchCase(match_case.pattern, match_case.guard, new_body),
              ]),
            )
          option.None -> option.None
        }
    }
  })
}

// Transforms a driver case body into its inlined equivalent: single-use nested
// `_fn_case_N` drivers are inlined first, then the body's tail decides how the
// result flows (rebind parameters, return a value, or assign to `target`).
fn inline_case_body(
  body: List(python.Statement),
  parameters: List(python.FunctionParameter),
  position: DriverPosition,
) -> option.Option(List(python.Statement)) {
  case inline_nested_drivers(body, parameters) {
    option.Some(inlined) ->
      // A `use`-desugar helper (`result.try`, `result.map`, `bool.guard`) invokes
      // the callback passed to it and returns its value unchanged, so a GleamTco
      // marker produced by a tail call inside the callback flows straight back
      // to the driver. The inlined loop has no `isinstance` dispatch to unpack
      // it, so such a body must keep the driver protocol.
      case passes_callback_to_known_callee(inlined) {
        True -> option.None
        False -> inline_tail(inlined, parameters, position)
      }
    option.None -> option.None
  }
}

// Whether a case body's tail hands a locally-defined function to one of the
// `use`-desugar helpers. If that callback tail-recurses it returns a `GleamTco`
// marker the helper passes through, which only the driver's `isinstance`
// dispatch can unpack.
fn passes_callback_to_known_callee(statements: List(python.Statement)) -> Bool {
  list.any(statements, fn(statement) {
    case statement {
      python.Return(expression) -> passes_local_callback(expression, statements)
      _ -> False
    }
  })
}

fn passes_local_callback(
  expression: python.Expression,
  statements: List(python.Statement),
) -> Bool {
  case expression {
    python.Call(callee, arguments) ->
      known_driver_callee(callee)
      && list.any(arguments, fn(field) {
        case field {
          python.UnlabelledField(python.Variable(arg_name)) ->
            is_local_function(arg_name, statements)
          python.LabelledField(_, python.Variable(arg_name)) ->
            is_local_function(arg_name, statements)
          _ -> False
        }
      })
    _ -> False
  }
}

fn is_local_function(name: String, statements: List(python.Statement)) -> Bool {
  list.any(statements, fn(statement) {
    case statement {
      python.FunctionDef(function) -> function.name == name
      _ -> False
    }
  })
}

// Handles the trailing statement of an inlined case body. After nested drivers
// are inlined the tail is either `return GleamTco((args))` (loop on), `return
// value` (return on), or a `match` left by an inlined tail-position driver
// whose own cases already loop or return.
fn inline_tail(
  body: List(python.Statement),
  parameters: List(python.FunctionParameter),
  position: DriverPosition,
) -> option.Option(List(python.Statement)) {
  case position {
    DriverPositionReturn ->
      case list.reverse(body) {
        [
          python.Return(python.Call(
            python.Variable("GleamTco"),
            [python.UnlabelledField(python.Tuple(fields))],
          )),
          ..preceding
        ] ->
          option.Some(list.append(
            list.reverse(preceding),
            rebind_parameters(parameters, fields),
          ))
        [python.Return(value), ..preceding] ->
          option.Some(
            list.append(list.reverse(preceding), [python.Return(value)]),
          )
        [python.Match(_, _), ..] -> option.Some(body)
        _ -> option.None
      }
    DriverPositionAssign(target) ->
      case list.reverse(body) {
        [python.Return(value), ..preceding] ->
          option.Some(
            list.append(list.reverse(preceding), [
              python.SimpleAssignment(target, value),
            ]),
          )
        [python.Match(_, _), ..] -> option.Some(body)
        _ -> option.None
      }
    DriverPositionOther -> option.None
  }
}

// Repeatedly inlines single-use `_fn_case_N` drivers found in `statements`.
// A driver is inlined when its body is a single `match` and it is invoked
// exactly once, either in return position (its value flows out of the case) or
// assigned to a variable (its value feeds a later statement, e.g. a tail call).
fn inline_nested_drivers(
  statements: List(python.Statement),
  parameters: List(python.FunctionParameter),
) -> option.Option(List(python.Statement)) {
  case statements {
    [] -> option.Some([])
    [statement, ..rest] ->
      case statement {
        python.FunctionDef(function) ->
          case
            is_inlinable_driver(function),
            find_driver_usage(statements, function.name)
          {
            True, option.Some(#(usage_position, subject)) ->
              case
                inline_driver_usage(
                  function,
                  subject,
                  parameters,
                  usage_position,
                )
              {
                option.Some(inlined) ->
                  inline_nested_drivers(
                    replace_usage(statements, function.name, inlined),
                    parameters,
                  )
                option.None -> option.None
              }
            _, _ ->
              case inline_nested_drivers(rest, parameters) {
                option.Some(new_rest) -> option.Some([statement, ..new_rest])
                option.None -> option.None
              }
          }
        _ ->
          case inline_nested_drivers(rest, parameters) {
            option.Some(new_rest) -> option.Some([statement, ..new_rest])
            option.None -> option.None
          }
      }
  }
}

// Inlines a single-use driver `function` (called with `subject`) into a `match`
// statement, processing each of its cases with `usage_position`.
fn inline_driver_usage(
  function: python.Function,
  subject: python.Expression,
  parameters: List(python.FunctionParameter),
  usage_position: DriverPosition,
) -> option.Option(List(python.Statement)) {
  case function.body {
    [python.Match(match_subject, cases)] ->
      case inline_driver_cases(cases, parameters, usage_position) {
        option.Some(inlined_cases) ->
          option.Some(inline_match_statements(
            match_subject,
            subject,
            inlined_cases,
          ))
        option.None -> option.None
      }
    _ -> option.None
  }
}

// A case driver inlinable by `inline_nested_drivers`: a `_fn_case_N`-shaped
// closure whose body is exactly one `match` (guards whose expressions are
// hoisted as `_fn_block_N` statements would break the direct inline).
fn is_inlinable_driver(function: python.Function) -> Bool {
  case function.body {
    [python.Match(_, _)] -> True
    _ -> False
  }
}

// Whether `name` is invoked exactly once in `statements` and from an
// inlinable position (`return name(subject)` or `x = name(subject)`). Returns
// `None` for multiple or non-inlinable uses so the driver is left alone.
fn find_driver_usage(
  statements: List(python.Statement),
  name: String,
) -> option.Option(#(DriverPosition, python.Expression)) {
  case driver_usage_sites(statements, name) {
    [#(position, subject)] ->
      case position {
        DriverPositionOther -> option.None
        _ -> option.Some(#(position, subject))
      }
    _ -> option.None
  }
}

// The driver call sites within `statements`. A `FunctionDef` itself is not a
// use; a call in any position other than return/assignment is recorded as
// `DriverPositionOther` so the driver is not inlined.
fn driver_usage_sites(
  statements: List(python.Statement),
  name: String,
) -> List(#(DriverPosition, python.Expression)) {
  list.filter_map(statements, fn(statement) {
    case statement {
      python.SimpleAssignment(
        target,
        python.Call(python.Variable(callee), [python.UnlabelledField(subject)]),
      )
        if callee == name
      -> Ok(#(DriverPositionAssign(target: target), subject))
      python.Return(python.Call(
        python.Variable(callee),
        [python.UnlabelledField(subject)],
      ))
        if callee == name
      -> Ok(#(DriverPositionReturn, subject))
      python.FunctionDef(function) if function.name == name -> Error(Nil)
      _ ->
        case statement_invokes_driver(statement, name) {
          True -> Ok(#(DriverPositionOther, python.Nil))
          False -> Error(Nil)
        }
    }
  })
}

// Removes the driver's definition and replaces its call site with `inlined`.
fn replace_usage(
  statements: List(python.Statement),
  name: String,
  inlined: List(python.Statement),
) -> List(python.Statement) {
  case statements {
    [] -> []
    [statement, ..rest] ->
      case statement {
        python.FunctionDef(function) if function.name == name ->
          replace_usage(rest, name, inlined)
        python.SimpleAssignment(
          _,
          python.Call(python.Variable(callee), [python.UnlabelledField(_)]),
        )
          if callee == name
        -> list.append(inlined, rest)
        python.Return(python.Call(
          python.Variable(callee),
          [python.UnlabelledField(_)],
        ))
          if callee == name
        -> list.append(inlined, rest)
        _ -> [statement, ..replace_usage(rest, name, inlined)]
      }
  }
}

// Whether any statement in a driver case body calls `name` in a position other
// than a top-level `return name(...)` / `x = name(...)`. Such a use would break
// the inline, so it makes the driver non-inlinable.
fn statement_invokes_driver(statement: python.Statement, name: String) -> Bool {
  case statement {
    python.Expression(expression) -> expression_invokes_driver(expression, name)
    python.Return(expression) -> expression_invokes_driver(expression, name)
    python.FunctionDef(_) -> False
    python.SimpleAssignment(_, value) -> expression_invokes_driver(value, name)
    python.MultipleAssignment(_, value) ->
      expression_invokes_driver(value, name)
    python.Match(subject, cases) ->
      expression_invokes_driver(subject, name)
      || list.any(cases, fn(match_case) {
        let python.MatchCase(_, guard, body) = match_case
        let guard_invokes = case guard {
          option.Some(expression) -> expression_invokes_driver(expression, name)
          option.None -> False
        }
        guard_invokes
        || list.any(body, fn(s) { statement_invokes_driver(s, name) })
      })
    python.While(_, body) ->
      list.any(body, fn(s) { statement_invokes_driver(s, name) })
    python.If(_, body) ->
      list.any(body, fn(s) { statement_invokes_driver(s, name) })
    python.For(_, _, body) ->
      list.any(body, fn(s) { statement_invokes_driver(s, name) })
  }
}

fn expression_invokes_driver(
  expression: python.Expression,
  name: String,
) -> Bool {
  case expression {
    python.String(_) -> False
    python.Number(_) -> False
    python.Bool(_) -> False
    python.Nil -> False
    python.Variable(_) -> False
    python.ModuleRef(_) -> False
    python.Tuple(elements) ->
      list.any(elements, fn(e) { expression_invokes_driver(e, name) })
    python.Negate(e) -> expression_invokes_driver(e, name)
    python.Not(e) -> expression_invokes_driver(e, name)
    python.Panic(e) -> expression_invokes_driver(e, name)
    python.Todo(e) -> expression_invokes_driver(e, name)
    python.Lambda(_, body) -> expression_invokes_driver(body, name)
    python.List(elements) ->
      list.any(elements, fn(e) { expression_invokes_driver(e, name) })
    python.ListWithRest(elements, rest) ->
      list.any(elements, fn(e) { expression_invokes_driver(e, name) })
      || expression_invokes_driver(rest, name)
    python.TupleIndex(tuple, _) -> expression_invokes_driver(tuple, name)
    python.FieldAccess(container, _) ->
      expression_invokes_driver(container, name)
    python.Call(python.Variable(callee), _) if callee == name -> True
    python.Call(function, arguments) ->
      expression_invokes_driver(function, name)
      || list.any(arguments, fn(field) {
        case field {
          python.UnlabelledField(item) -> expression_invokes_driver(item, name)
          python.LabelledField(_, item) -> expression_invokes_driver(item, name)
        }
      })
    python.RecordUpdate(record, fields) ->
      expression_invokes_driver(record, name)
      || list.any(fields, fn(field) {
        case field {
          python.UnlabelledField(item) -> expression_invokes_driver(item, name)
          python.LabelledField(_, item) -> expression_invokes_driver(item, name)
        }
      })
    python.BinaryOperator(_, left, right) ->
      expression_invokes_driver(left, name)
      || expression_invokes_driver(right, name)
    python.Slice(container, start, end) ->
      expression_invokes_driver(container, name)
      || expression_invokes_driver(start, name)
      || {
        case end {
          option.Some(e) -> expression_invokes_driver(e, name)
          option.None -> False
        }
      }
    python.AssignmentExpression(_, value) ->
      expression_invokes_driver(value, name)
    python.IsNotNone(e) -> expression_invokes_driver(e, name)
    python.BitString(_) -> False
    python.Dict(_) -> False
  }
}

// Reassigns the function's parameters from the `GleamTco` args tuple, so the
// loop continues with the new values.
fn rebind_parameters(
  parameters: List(python.FunctionParameter),
  fields: List(python.Expression),
) -> List(python.Statement) {
  let names = parameter_names(parameters)
  case names {
    [] ->
      // A zero-argument tail-recursive call has nothing to rebind; the
      // MatchCase body is empty, which the generator renders as `pass`, and
      // the `while True` loop carries on to the next iteration.
      []
    [single] ->
      // With a single parameter the field is the new value directly; there is
      // no tuple to build and index.
      case fields {
        [field] -> [python.SimpleAssignment(single, field)]
        _ -> []
      }
    multiple -> [
      python.MultipleAssignment(multiple, python.Tuple(fields)),
    ]
  }
}

// Reassigns the function's parameters from the `_Tco` result. With a single
// parameter the tuple must be unpacked with an index, since `n = args` would
// assign the whole tuple.
fn unpack_result(
  parameters: List(python.FunctionParameter),
) -> List(python.Statement) {
  let names = parameter_names(parameters)
  case names {
    [] ->
      // A zero-argument tail-recursive call has nothing to unpack: the
      // MatchCase body is empty, which the generator renders as `pass`, and
      // the `while True` loop carries on to the next iteration.
      []
    [single] -> [
      python.SimpleAssignment(
        single,
        python.TupleIndex(
          python.FieldAccess(python.Variable("_result"), "args"),
          0,
        ),
      ),
    ]
    multiple -> [
      python.MultipleAssignment(
        multiple,
        python.FieldAccess(python.Variable("_result"), "args"),
      ),
    ]
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
// (`list.any`, `list.map`, `list.fold`) would swallow the marker, so a
// function passed to one of those callees is not a tail driver.
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
    python.Call(callee, arguments) ->
      // A nested function is only a tail driver when the call it is passed to
      // is guaranteed to invoke it in tail position and propagate its result
      // back to the enclosing driver. The compiler-recognized `use` helpers
      // (`result.try`, `result.map`, `bool.guard`) do this. A function passed
      // to any other callee may instead be *stored* (e.g. a streaming parser
      // that holds a continuation in a record to resume later); rewriting its
      // self-call into a `GleamTco` marker would leak that marker to whoever
      // later invokes the stored closure.
      case known_driver_callee(callee) {
        True ->
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
        False -> False
      }
    _ -> False
  }
}

// The compiler-generated helpers that `use` desugars to, plus the stdlib
// functions whose compiled form invokes a callback and returns its value
// unchanged (so a `GleamTco` marker flows through to the driver).
fn known_driver_callee(callee: python.Expression) -> Bool {
  let name = case callee {
    python.Variable(name) -> name
    python.FieldAccess(python.ModuleRef(module), function_name) ->
      module <> "." <> function_name
    python.FieldAccess(python.Variable(module), function_name) ->
      module <> "." <> function_name
    _ -> ""
  }
  name == "result.try"
  || name == "result.map"
  || name == "bool.guard"
  || name == "result.lazy_try"
  || name == "result.lazy_unwrap"
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

// Every `case` expression is compiled to a `_fn_case_N` closure wrapping a
// single `match`. That closure allocation and call is pure overhead, so inline
// single-use drivers back into their call sites:
//
//     def _fn_case_0(_case_subject):
//         match _case_subject:
//             case Some(v):
//                 return v + 1
//             case None:
//                 return 0
//     x = _fn_case_0(subject)
//
// becomes
//
//     match subject:
//         case Some(v):
//             x = v + 1
//         case None:
//             x = 0
//
// Python's `match` does not scope its pattern captures or the names bound in
// case bodies, so inlining leaks them into the enclosing function scope. A
// driver is only inlined when none of those leaked names are referenced by any
// other statement of the enclosing scope, so a later use cannot silently pick
// up the leaked value. `resolve_tail_calls` must run first: its drivers use
// the `GleamTco` protocol, which this pass refuses to touch.
pub fn inline_case_drivers(
  statements: List(python.Statement),
) -> List(python.Statement) {
  inline_scope(statements)
}

fn inline_scope(statements: List(python.Statement)) -> List(python.Statement) {
  case find_and_inline_driver(statements) {
    option.Some(inlined) -> inline_scope(inlined)
    option.None -> recurse_nested_scopes(statements)
  }
}

// Inlines the first safe single-use case driver found among the top-level
// statements. Returns `None` when there is none. `prefix` carries the
// statements seen so far so they are not dropped when the driver is later in
// the list.
fn find_and_inline_driver(
  statements: List(python.Statement),
) -> option.Option(List(python.Statement)) {
  find_driver_in_statements(statements, [])
}

fn find_driver_in_statements(
  statements: List(python.Statement),
  prefix: List(python.Statement),
) -> option.Option(List(python.Statement)) {
  case statements {
    [] -> option.None
    [statement, ..rest] ->
      case statement {
        python.FunctionDef(function) ->
          case
            is_inlinable_driver(function)
            && !statement_contains_gleam_tco(statement),
            find_driver_usage(statements, function.name)
          {
            True, option.Some(#(position, subject)) ->
              case
                driver_leak_safe(
                  function,
                  subject,
                  list.append(prefix, statements),
                )
              {
                True ->
                  case simple_inline_driver(function, subject, position) {
                    option.Some(inlined) ->
                      option.Some(list.append(
                        prefix,
                        replace_usage(statements, function.name, inlined),
                      ))
                    option.None ->
                      find_driver_in_statements(
                        rest,
                        list.append(prefix, [statement]),
                      )
                  }
                False ->
                  find_driver_in_statements(
                    rest,
                    list.append(prefix, [statement]),
                  )
              }
            _, _ ->
              find_driver_in_statements(rest, list.append(prefix, [statement]))
          }
        _ -> find_driver_in_statements(rest, list.append(prefix, [statement]))
      }
  }
}

// Inlines a single-use case driver without touching nested drivers (they stay
// closures, keeping their captures scoped). A driver whose cases end in
// `return GleamTco(...)` is a tail-recursion driver owned by
// `resolve_tail_calls`, so it is left alone.
fn simple_inline_driver(
  function: python.Function,
  subject: python.Expression,
  position: DriverPosition,
) -> option.Option(List(python.Statement)) {
  case function.body {
    [python.Match(match_subject, cases)] ->
      case simple_inline_cases(cases, position) {
        option.Some(inlined_cases) ->
          case position {
            DriverPositionOther -> option.None
            _ ->
              option.Some(inline_match_statements(
                match_subject,
                subject,
                inlined_cases,
              ))
          }
        option.None -> option.None
      }
    _ -> option.None
  }
}

fn simple_inline_cases(
  cases: List(python.MatchCase),
  position: DriverPosition,
) -> option.Option(List(python.MatchCase)) {
  list.fold(cases, option.Some([]), fn(acc, match_case) {
    case acc {
      option.None -> option.None
      option.Some(inlined) ->
        case simple_inline_case(match_case, position) {
          option.Some(rewritten) ->
            option.Some(list.append(inlined, [rewritten]))
          option.None -> option.None
        }
    }
  })
}

fn simple_inline_case(
  match_case: python.MatchCase,
  position: DriverPosition,
) -> option.Option(python.MatchCase) {
  let python.MatchCase(pattern, guard, body) = match_case
  case list.reverse(body) {
    [python.Return(python.Call(python.Variable("GleamTco"), _)), ..] ->
      option.None
    [python.Return(value), ..preceding] ->
      case position {
        DriverPositionReturn ->
          option.Some(python.MatchCase(
            pattern,
            guard,
            list.append(list.reverse(preceding), [python.Return(value)]),
          ))
        DriverPositionAssign(target) ->
          option.Some(python.MatchCase(
            pattern,
            guard,
            list.append(list.reverse(preceding), [
              python.SimpleAssignment(target, value),
            ]),
          ))
        DriverPositionOther -> option.None
      }
    _ -> option.None
  }
}

// Whether inlining the driver can leak a name into the enclosing scope that
// another statement references. The names an inlined match binds are the
// pattern captures and the binds of each case body (all of which Python leaves
// in the enclosing function scope). A reference to one of those names from any
// other statement, or from the match subject itself, would change meaning or
// (for a subject reference) become an unbound local, so the driver is not
// inlined.
fn driver_leak_safe(
  function: python.Function,
  subject: python.Expression,
  statements: List(python.Statement),
) -> Bool {
  case driver_leaked_names(function) {
    [] -> True
    leaked -> {
      let others = statements_without_driver_and_use(statements, function.name)
      list.all(leaked, fn(name) {
        !expression_references(subject, name)
        && !list.any(others, fn(statement) {
          list.contains(
            deep_statement_refs(statement, set.new(), set.new()),
            name,
          )
        })
      })
    }
  }
}

fn driver_leaked_names(function: python.Function) -> List(String) {
  case function.body {
    [python.Match(_, cases)] -> {
      let pattern_names =
        cases
        |> list.map(fn(match_case) { pattern_binds(match_case.pattern) })
        |> list.flatten
      let body_names =
        cases
        |> list.map(fn(match_case) {
          match_case.body |> list.map(statement_binds) |> list.flatten
        })
        |> list.flatten
      pattern_names |> list.append(body_names) |> list.unique
    }
    _ -> []
  }
}

// The statements of a scope other than a driver's own definition and its call
// site.
fn statements_without_driver_and_use(
  statements: List(python.Statement),
  name: String,
) -> List(python.Statement) {
  list.filter(statements, fn(statement) {
    case statement {
      python.FunctionDef(function) if function.name == name -> False
      python.SimpleAssignment(
        _,
        python.Call(python.Variable(callee), [python.UnlabelledField(_)]),
      )
        if callee == name
      -> False
      python.Return(python.Call(
        python.Variable(callee),
        [python.UnlabelledField(_)],
      ))
        if callee == name
      -> False
      _ -> True
    }
  })
}

fn recurse_nested_scopes(
  statements: List(python.Statement),
) -> List(python.Statement) {
  list.map(statements, fn(statement) {
    case statement {
      python.Match(subject, cases) ->
        python.Match(
          subject: subject,
          cases: list.map(cases, fn(match_case) {
            let python.MatchCase(pattern, guard, body) = match_case
            python.MatchCase(pattern, guard, inline_scope(body))
          }),
        )
      python.While(condition, body) ->
        python.While(condition: condition, body: inline_scope(body))
      python.If(condition, body) ->
        python.If(condition: condition, body: inline_scope(body))
      python.FunctionDef(function) ->
        // A function that is part of the tail-recursion trampoline (it returns
        // or passes a `GleamTco` marker) is opaque to this pass: inlining
        // drivers inside its case bodies would break the enclosing
        // `isinstance` dispatch.
        case statement_contains_gleam_tco(statement) {
          True -> statement
          False ->
            python.FunctionDef(
              python.Function(..function, body: inline_scope(function.body)),
            )
        }
      _ -> statement
    }
  })
}

// Whether a statement tree references the `GleamTco` marker, which only the
// tail-recursion machinery produces. Such statements are part of the trampoline
// and must not be rewritten by the case-driver inliner.
fn statement_contains_gleam_tco(statement: python.Statement) -> Bool {
  case statement {
    python.Expression(expression) -> expression_contains_gleam_tco(expression)
    python.Return(expression) -> expression_contains_gleam_tco(expression)
    python.SimpleAssignment(_, value) -> expression_contains_gleam_tco(value)
    python.MultipleAssignment(_, value) -> expression_contains_gleam_tco(value)
    python.FunctionDef(function) ->
      list.any(function.body, statement_contains_gleam_tco)
    python.Match(subject, cases) ->
      expression_contains_gleam_tco(subject)
      || list.any(cases, fn(match_case) {
        let python.MatchCase(_, guard, body) = match_case
        let guard_contains = case guard {
          option.Some(expression) -> expression_contains_gleam_tco(expression)
          option.None -> False
        }
        guard_contains || list.any(body, statement_contains_gleam_tco)
      })
    python.While(_, body) -> list.any(body, statement_contains_gleam_tco)
    python.If(_, body) -> list.any(body, statement_contains_gleam_tco)
    python.For(_, _, body) -> list.any(body, statement_contains_gleam_tco)
  }
}

fn expression_contains_gleam_tco(expression: python.Expression) -> Bool {
  case expression {
    python.String(_) -> False
    python.Number(_) -> False
    python.Bool(_) -> False
    python.Nil -> False
    python.Variable(_) -> False
    python.ModuleRef(_) -> False
    python.Tuple(elements) -> list.any(elements, expression_contains_gleam_tco)
    python.Negate(e) -> expression_contains_gleam_tco(e)
    python.Not(e) -> expression_contains_gleam_tco(e)
    python.Panic(e) -> expression_contains_gleam_tco(e)
    python.Todo(e) -> expression_contains_gleam_tco(e)
    python.Lambda(_, body) -> expression_contains_gleam_tco(body)
    python.List(elements) -> list.any(elements, expression_contains_gleam_tco)
    python.ListWithRest(elements, rest) ->
      list.any(elements, expression_contains_gleam_tco)
      || expression_contains_gleam_tco(rest)
    python.TupleIndex(tuple, _) -> expression_contains_gleam_tco(tuple)
    python.FieldAccess(container, _) -> expression_contains_gleam_tco(container)
    python.Call(python.Variable("GleamTco"), _) -> True
    python.Call(function, arguments) ->
      expression_contains_gleam_tco(function)
      || list.any(arguments, fn(field) {
        case field {
          python.UnlabelledField(item) -> expression_contains_gleam_tco(item)
          python.LabelledField(_, item) -> expression_contains_gleam_tco(item)
        }
      })
    python.RecordUpdate(record, fields) ->
      expression_contains_gleam_tco(record)
      || list.any(fields, fn(field) {
        case field {
          python.UnlabelledField(item) -> expression_contains_gleam_tco(item)
          python.LabelledField(_, item) -> expression_contains_gleam_tco(item)
        }
      })
    python.BinaryOperator(_, left, right) ->
      expression_contains_gleam_tco(left)
      || expression_contains_gleam_tco(right)
    python.Slice(container, start, end) ->
      expression_contains_gleam_tco(container)
      || expression_contains_gleam_tco(start)
      || {
        case end {
          option.Some(e) -> expression_contains_gleam_tco(e)
          option.None -> False
        }
      }
    python.AssignmentExpression(_, value) ->
      expression_contains_gleam_tco(value)
    python.IsNotNone(e) -> expression_contains_gleam_tco(e)
    python.BitString(_) -> False
    python.Dict(_) -> False
  }
}

// Rewrites the list iteration loops left by `resolve_tail_calls` into a
// `while isinstance(list, GleamList)` loop. Python's `match` dispatches a
// two-case list (EmptyGleamList / GleamList) with two `isinstance` checks plus
// `__match_args__` unpacking per element; a plain `isinstance` check and two
// attribute reads are several times faster:
//
//     while True:
//         match list:
//             case EmptyGleamList():
//                 return initial
//             case GleamList(first, rest):
//                 list, initial, fun = (rest, fun(initial, first), fun,)
//
// becomes
//
//     while isinstance(list, GleamList):
//         first = list.value
//         rest = list.tail
//         list, initial, fun = (rest, fun(initial, first), fun,)
//     return initial
//
// The match must have exactly two cases: a `GleamList(first, rest)` cons case
// and a capture-free base case (EmptyGleamList or a wildcard) that ends the
// loop with a value. Anything else (guards, alternate patterns, a base case
// that binds names, or more than two cases) is left untouched.
pub fn optimize_list_loops(
  statements: List(python.Statement),
) -> List(python.Statement) {
  list.fold(statements, [], fn(acc, statement) {
    case statement {
      python.While(python.Bool("True"), [python.Match(subject, cases)]) ->
        case list_loop_rewrite(subject, cases) {
          option.Some(rewritten) ->
            list.append(acc, optimize_list_loops(rewritten))
          option.None ->
            list.append(acc, [
              python.While(
                python.Bool("True"),
                optimize_list_loops([
                  python.Match(subject: subject, cases: cases),
                ]),
              ),
            ])
        }
      python.While(condition, body) ->
        list.append(acc, [
          python.While(condition: condition, body: optimize_list_loops(body)),
        ])
      python.Match(subject, cases) ->
        list.append(acc, [
          python.Match(
            subject: subject,
            cases: list.map(cases, fn(match_case) {
              let python.MatchCase(pattern, guard, body) = match_case
              python.MatchCase(pattern, guard, optimize_list_loops(body))
            }),
          ),
        ])
      python.FunctionDef(function) ->
        list.append(acc, [
          python.FunctionDef(
            python.Function(
              ..function,
              body: optimize_list_loops(function.body),
            ),
          ),
        ])
      python.If(condition, body) ->
        list.append(acc, [
          python.If(condition: condition, body: optimize_list_loops(body)),
        ])
      _ -> list.append(acc, [statement])
    }
  })
}

fn list_loop_rewrite(
  subject: python.Expression,
  cases: List(python.MatchCase),
) -> option.Option(List(python.Statement)) {
  case subject, cases {
    python.Variable(subject_name), [case_a, case_b] ->
      case list_cons_case(case_a), list_base_case(case_b) {
        option.Some(#(first, rest)), option.Some(base_value) ->
          option.Some(build_list_loop(
            subject_name,
            first,
            rest,
            case_a.body,
            base_value,
          ))
        _, _ ->
          case list_cons_case(case_b), list_base_case(case_a) {
            option.Some(#(first, rest)), option.Some(base_value) ->
              option.Some(build_list_loop(
                subject_name,
                first,
                rest,
                case_b.body,
                base_value,
              ))
            _, _ -> option.None
          }
      }
    _, _ -> option.None
  }
}

// The recursive cons case: `case [first, ..rest]: <rebind>`.
fn list_cons_case(
  match_case: python.MatchCase,
) -> option.Option(#(String, String)) {
  case match_case {
    python.MatchCase(
      python.PatternList(
        [python.PatternVariable(first)],
        option.Some(python.PatternVariable(rest)),
      ),
      option.None,
      _,
    ) -> option.Some(#(first, rest))
    _ -> option.None
  }
}

// The base case: `case []: return value` (or `case _:`), binding no names, that
// ends the loop.
fn list_base_case(
  match_case: python.MatchCase,
) -> option.Option(python.Expression) {
  case match_case {
    python.MatchCase(pattern, option.None, [python.Return(value)]) ->
      case pattern {
        python.PatternList([], option.None) -> option.Some(value)
        python.PatternWildcard -> option.Some(value)
        _ -> option.None
      }
    _ -> option.None
  }
}

fn build_list_loop(
  subject_name: String,
  first: String,
  rest: String,
  cons_body: List(python.Statement),
  base_value: python.Expression,
) -> List(python.Statement) {
  // Read both fields before a binding can clobber the subject: the pattern
  // captures can share the subject's name (e.g. `append_loop(first, second)`
  // matches `[first, ..rest]`), so the binding that shares the subject name
  // must come last.
  let bindings = case first == subject_name {
    True -> [
      python.SimpleAssignment(
        rest,
        python.FieldAccess(python.Variable(subject_name), "tail"),
      ),
      python.SimpleAssignment(
        first,
        python.FieldAccess(python.Variable(subject_name), "value"),
      ),
    ]
    False -> [
      python.SimpleAssignment(
        first,
        python.FieldAccess(python.Variable(subject_name), "value"),
      ),
      python.SimpleAssignment(
        rest,
        python.FieldAccess(python.Variable(subject_name), "tail"),
      ),
    ]
  }
  [
    python.While(
      python.BinaryOperator(
        python.Is,
        python.Call(python.Variable("type"), [
          python.UnlabelledField(python.Variable(subject_name)),
        ]),
        python.Variable("GleamList"),
      ),
      list.append(bindings, cons_body),
    ),
    python.Return(base_value),
  ]
}

// Inlines `list.fold` / `dict.fold` calls whose callback is an anonymous
// `_fn_def_N` into a `while`/`for` loop in the caller, removing the stdlib
// call and the per-element closure dispatch:
//
//     x = list.fold(items, 0, _fn_def_3)
//
// becomes
//
//     _gleam_fold_list = items
//     _gleam_fold_acc = 0
//     while type(_gleam_fold_list) is GleamList:
//         _gleam_fold_item = _gleam_fold_list.value
//         _gleam_fold_rest = _gleam_fold_list.tail
//         _gleam_fold_list = _gleam_fold_rest
//         <callback params bound to loop vars>
//         <callback body, returns rewritten to `_gleam_fold_acc = ...`>
//     x = _gleam_fold_acc
//
// Python's `while`/`for` bodies do not scope their locals, so splicing the
// callback body leaks its binds (params, lets, case captures, the callback's
// own name) into the enclosing function scope. Like `inline_case_drivers`, a
// fold is only inlined when none of those leaked names are referenced by any
// other statement of the scope, so a later use cannot silently pick up the
// leaked value.
pub fn inline_fold_loops(
  statements: List(python.Statement),
  module_paths: option.Option(dict.Dict(String, String)),
) -> List(python.Statement) {
  case module_paths {
    option.None -> statements
    option.Some(paths) -> {
      let #(inlined, _) =
        inline_fold_scope(statements, option.Some(paths), 0, statements, False)
      inlined
    }
  }
}

// Every inlined fold's loop-local names must be unique within the scope they
// are spliced into: a fold nested inside another fold's callback would
// otherwise clobber the outer loop's `_gleam_fold_*` locals (and rebind its
// callback parameters) with the same names. `serial` is bumped once per
// inlined fold so each gets a distinct set.
fn inline_fold_scope(
  statements: List(python.Statement),
  module_paths: option.Option(dict.Dict(String, String)),
  serial: Int,
  enclosing: List(python.Statement),
  nested nested: Bool,
) -> #(List(python.Statement), Int) {
  case
    find_and_inline_fold(statements, module_paths, serial, enclosing, nested)
  {
    option.Some(#(inlined, serial)) ->
      inline_fold_scope(inlined, module_paths, serial, enclosing, nested)
    option.None ->
      recurse_fold_scopes(statements, module_paths, serial, enclosing, nested)
  }
}

type FoldCall {
  FoldCall(
    path: String,
    callback: String,
    collection: python.Expression,
    initial: python.Expression,
  )
}

type FoldTarget {
  FoldAssign(List(String))
  FoldReturn
  // The fold's result is an intermediate value consumed by an enclosing
  // expression (e.g. `result.try_(list.fold(...), next)`). The loop's
  // accumulator variable is referenced directly in place of the fold call.
  FoldTemp
}

// Where a detected fold sits inside its statement's value expression.
type WrapperLocation {
  // The statement's value expression is the fold call itself.
  WrapperRoot
  // The fold is the `index`-th argument of a call whose other arguments /
  // call target are described by `over`.
  WrapperArgument(index: Int, over: WrapperLocation)
  // The fold is the call target (function position) of a call whose
  // arguments are described by `over` (fold calls do not appear there, but the
  // path is kept uniform).
  WrapperFunction(over: WrapperLocation)
}

// Rewrites the first inlinable fold call found among the top-level statements
// into its loop, replacing the fold statement and removing the callback def.
// Returns the rewritten statements together with the next `serial`, bumping it
// when an inline actually happens.
fn find_and_inline_fold(
  statements: List(python.Statement),
  module_paths: option.Option(dict.Dict(String, String)),
  serial: Int,
  enclosing: List(python.Statement),
  nested nested: Bool,
) -> option.Option(#(List(python.Statement), Int)) {
  fold_inline_in_statements(
    statements,
    [],
    module_paths,
    serial,
    enclosing,
    nested,
  )
}

fn fold_inline_in_statements(
  statements: List(python.Statement),
  prefix: List(python.Statement),
  module_paths: option.Option(dict.Dict(String, String)),
  serial: Int,
  enclosing: List(python.Statement),
  nested nested: Bool,
) -> option.Option(#(List(python.Statement), Int)) {
  case statements {
    [] -> option.None
    [statement, ..rest] ->
      case statement_value(statement) {
        option.None ->
          fold_inline_in_statements(
            rest,
            list.append(prefix, [statement]),
            module_paths,
            serial,
            enclosing,
            nested,
          )
        option.Some(expression) ->
          case find_fold_place(expression, module_paths) {
            option.None ->
              fold_inline_in_statements(
                rest,
                list.append(prefix, [statement]),
                module_paths,
                serial,
                enclosing,
                nested,
              )
            option.Some(#(call, location)) ->
              case
                fold_callback_def(
                  list.append(prefix, statements),
                  call.callback,
                )
              {
                option.None ->
                  fold_inline_in_statements(
                    rest,
                    list.append(prefix, [statement]),
                    module_paths,
                    serial,
                    enclosing,
                    nested,
                  )
                option.Some(function) -> {
                  let others =
                    list.filter(list.append(prefix, statements), fn(other) {
                      case other {
                        python.FunctionDef(other_function)
                          if other_function.name == call.callback
                        -> False
                        _ -> True
                      }
                    })
                  // For a fold nested in a wrapper expression the loop's
                  // accumulator is the result: the wrapper reads it directly,
                  // so no extra finish statement is produced.
                  let target = case location {
                    WrapperRoot -> statement_target(statement)
                    _ -> FoldTemp
                  }
                  let names = fold_names(call.path, serial)
                  case
                    build_fold_inline(
                      function,
                      call,
                      others,
                      serial,
                      enclosing,
                      target,
                      nested,
                    )
                  {
                    option.None ->
                      fold_inline_in_statements(
                        rest,
                        list.append(prefix, [statement]),
                        module_paths,
                        serial,
                        enclosing,
                        nested,
                      )
                    option.Some(inlined) -> {
                      let rebuilt = case location {
                        WrapperRoot -> option.None
                        _ ->
                          option.Some(replace_statement_value(
                            statement,
                            replace_fold_place(
                              expression,
                              location,
                              python.Variable(names.acc),
                            ),
                          ))
                      }
                      option.Some(#(
                        list.append(
                          list.filter(prefix, fn(other) {
                            case other {
                              python.FunctionDef(other_function)
                                if other_function.name == call.callback
                              -> False
                              _ -> True
                            }
                          }),
                          list.append(
                            list.append(inlined, case rebuilt {
                              option.Some(rebuilt_statement) -> [
                                rebuilt_statement,
                              ]
                              option.None -> []
                            }),
                            list.filter(rest, fn(other) {
                              case other {
                                python.FunctionDef(other_function)
                                  if other_function.name == call.callback
                                -> False
                                _ -> True
                              }
                            }),
                          ),
                        ),
                        serial + 1,
                      ))
                    }
                  }
                }
              }
          }
      }
  }
}

// The value expression of a statement, when the statement can host a fold.
fn statement_value(
  statement: python.Statement,
) -> option.Option(python.Expression) {
  case statement {
    python.SimpleAssignment(_, value) -> option.Some(value)
    python.MultipleAssignment(_, value) -> option.Some(value)
    python.Return(value) -> option.Some(value)
    _ -> option.None
  }
}

fn statement_target(statement: python.Statement) -> FoldTarget {
  case statement {
    python.SimpleAssignment(name, _) -> FoldAssign([name])
    python.MultipleAssignment(names, _) -> FoldAssign(names)
    python.Return(_) -> FoldReturn
    _ -> FoldTemp
  }
}

fn replace_statement_value(
  statement: python.Statement,
  expression: python.Expression,
) -> python.Statement {
  case statement {
    python.SimpleAssignment(name, _) ->
      python.SimpleAssignment(name, expression)
    python.MultipleAssignment(names, _) ->
      python.MultipleAssignment(names, expression)
    python.Return(_) -> python.Return(expression)
    _ -> statement
  }
}

// Inlines a fold call. The callback's parameters and body-local names are
// spliced into the enclosing function scope (Python loops do not scope their
// locals), so any that collide with a name the surrounding statements
// reference are renamed to fresh `_gleam_fold`-suffixed names first. The
// callback body is internally shadow-unambiguous (it passed the shadowing
// passes as a standalone function), so a plain global substitution of the
// colliding names is correct there. Names the callback merely reads from the
// enclosing scope are not renamed: they are the same variables after the
// splice.
fn build_fold_inline(
  function: python.Function,
  call: FoldCall,
  others: List(python.Statement),
  serial: Int,
  enclosing: List(python.Statement),
  target: FoldTarget,
  nested nested: Bool,
) -> option.Option(List(python.Statement)) {
  // A fold spliced into a nested block (a case arm or the body of an
  // if/while/for) cannot see references made after that block within the same
  // function scope, so a callback parameter shared with such a reference is
  // silently clobbered by the loop's per-iteration rebinding instead of being
  // renamed. Folds located in nested blocks keep closure form, which is
  // always correct.
  case nested {
    True -> option.None
    False ->
      build_fold_inline_top_level(
        function,
        call,
        others,
        serial,
        enclosing,
        target,
      )
  }
}

fn build_fold_inline_top_level(
  function: python.Function,
  call: FoldCall,
  others: List(python.Statement),
  serial: Int,
  enclosing: List(python.Statement),
  target: FoldTarget,
) -> option.Option(List(python.Statement)) {
  // A callback whose body declares nested functions must not be inlined:
  // those closures may capture the callback's parameters, and after the
  // splice their free references would resolve to the loop variables, which
  // are reassigned on every iteration (Python closures bind by reference).
  // Such folds keep the ordinary closure-dispatch form, which is correct.
  let parameter_names =
    list.filter_map(function.parameters, fn(parameter) {
      case parameter {
        python.NameParam(name) -> Ok(name)
        python.DiscardParam(_) -> Error(Nil)
      }
    })
  // Hoisted sibling function definitions execute lazily: if one captures a
  // callback parameter, splicing the callback into a loop makes that capture
  // alias the mutated loop variable. Plain sibling references to a parameter
  // are safe — the rename pass mints fresh names for exactly those.
  let captured_by_sibling =
    list.any(others, fn(statement) {
      case statement {
        python.FunctionDef(_) ->
          deep_statement_refs(statement, set.new(), set.new())
          |> list.any(fn(name) { list.contains(parameter_names, name) })
        _ -> False
      }
    })
  case fold_body_has_nested_defs(function.body) || captured_by_sibling {
    True -> option.None
    False ->
      build_fold_inline_checked(
        function,
        call,
        others,
        serial,
        enclosing,
        target,
      )
  }
}

fn build_fold_inline_checked(
  function: python.Function,
  call: FoldCall,
  others: List(python.Statement),
  serial: Int,
  enclosing: List(python.Statement),
  target: FoldTarget,
) -> option.Option(List(python.Statement)) {
  let FoldNames(_, acc_name, _, _) = fold_names(call.path, serial)
  let parameter_names =
    list.filter_map(function.parameters, fn(parameter) {
      case parameter {
        python.NameParam(name) -> Ok(name)
        python.DiscardParam(_) -> Error(Nil)
      }
    })
  let referenced =
    fold_referenced(others)
    |> list.append(fold_enclosing_refs(enclosing, call.callback))
    |> list.unique
  let body_binds = flatten_body_leaked(function.body)
  let renames =
    parameter_names
    |> list.append(body_binds)
    |> list.append(fold_loop_names(call.path, serial))
    |> list.append([function.name])
    |> list.filter(fn(name) { list.contains(referenced, name) })
    |> list.fold(dict.new(), fn(acc, name) {
      let fresh = fold_fresh(name, referenced, acc)
      dict.insert(acc, name, fresh)
    })
  let parameters =
    list.map(function.parameters, fn(parameter) {
      case parameter {
        python.NameParam(name) ->
          python.NameParam(result.unwrap(dict.get(renames, name), name))
        python.DiscardParam(_) -> parameter
      }
    })
  let body =
    function.body
    |> list.map(fn(statement) {
      statement_substitute(statement, renames)
      |> replace_statement_returns(acc_name)
    })
  build_fold_loop(parameters, body, call, serial, target)
}

// True when any statement (at any depth) declares a function.
fn fold_body_has_nested_defs(statements: List(python.Statement)) -> Bool {
  case statements {
    [] -> False
    [statement, ..rest] ->
      case statement {
        python.FunctionDef(_) -> True
        python.Match(_, cases) ->
          list.any(cases, fn(case_) { fold_body_has_nested_defs(case_.body) })
        python.While(_, body) | python.If(_, body) | python.For(_, _, body) ->
          fold_body_has_nested_defs(body)
        _ -> False
      }
      || fold_body_has_nested_defs(rest)
  }
}

// The names the surrounding statements reference, so the splice can avoid
// clobbering any of them.
fn fold_referenced(statements: List(python.Statement)) -> List(String) {
  statements
  |> list.map(fn(statement) {
    deep_statement_refs(statement, set.new(), set.new())
  })
  |> list.flatten
  |> list.unique
}

// Every name used anywhere in the enclosing function body, regardless of the
// function scoping (a nested callback's `in_scope` does not matter here). A
// fold spliced into a nested scope leaks its callback parameters down to the
// whole enclosing function, so any use of the same name elsewhere - even
// inside another nested function - must force a rename. Only variable uses
// count: a name a nested function merely binds is not a use until it appears
// as a `Variable`. The callback being removed (`skip`) is ignored wherever it
// sits in the tree, since its body is spliced away rather than referenced.
fn fold_enclosing_refs(
  statements: List(python.Statement),
  skip: String,
) -> List(String) {
  statements
  |> list.map(fn(statement) { raw_statement_refs(statement, skip) })
  |> list.flatten
  |> list.unique
}

fn raw_statement_refs(
  statement: python.Statement,
  skip: String,
) -> List(String) {
  let refs = expression_refs(_, set.new())
  case statement {
    python.Expression(expression) | python.Return(expression) ->
      refs(expression)
    python.SimpleAssignment(_, value) -> refs(value)
    python.MultipleAssignment(_, value) -> refs(value)
    python.FunctionDef(function) ->
      case function.name == skip {
        True -> []
        False ->
          list.flatten(list.map(function.body, raw_statement_refs(_, skip)))
      }
    python.Match(subject, cases) ->
      list.append(
        refs(subject),
        list.flatten(
          list.map(cases, fn(match_case) {
            let python.MatchCase(_, guard, body) = match_case
            list.append(
              option.unwrap(option.map(guard, refs), []),
              list.flatten(list.map(body, raw_statement_refs(_, skip))),
            )
          }),
        ),
      )
    python.While(condition, body) ->
      list.append(
        refs(condition),
        list.flatten(list.map(body, raw_statement_refs(_, skip))),
      )
    python.If(condition, body) ->
      list.append(
        refs(condition),
        list.flatten(list.map(body, raw_statement_refs(_, skip))),
      )
    python.For(_, iterable, body) ->
      list.append(
        refs(iterable),
        list.flatten(list.map(body, raw_statement_refs(_, skip))),
      )
  }
}

// A fresh replacement name for a colliding callback name. Always distinct
// from the referenced names and from other replacements.
fn fold_fresh(
  name: String,
  referenced: List(String),
  renames: dict.Dict(String, String),
) -> String {
  let exists = fn(candidate) {
    list.contains(referenced, candidate)
    || list.contains(dict.values(renames), candidate)
  }
  let base = name <> "_gleam_fold"
  case exists(base) {
    False -> base
    True -> fold_next_fresh(base, 1, exists)
  }
}

fn fold_next_fresh(base: String, n: Int, exists: fn(String) -> Bool) -> String {
  let candidate = base <> "_" <> int.to_string(n)
  case exists(candidate) {
    True -> fold_next_fresh(base, n + 1, exists)
    False -> candidate
  }
}

// The callback definition for a fold call, when its arity matches the fold's
// callback signature (2 args for `gleam/list.fold`, 3 for `gleam/dict.fold`).
fn fold_callback_def(
  statements: List(python.Statement),
  callback: String,
) -> option.Option(python.Function) {
  case statements {
    [] -> option.None
    [statement, ..rest] ->
      case statement {
        python.FunctionDef(function) if function.name == callback -> {
          let param_count = list.length(function.parameters)
          case param_count {
            2 -> option.Some(function)
            3 -> option.Some(function)
            _ -> {
              fold_callback_def(rest, callback)
            }
          }
        }
        _ -> fold_callback_def(rest, callback)
      }
  }
}

// A statement that assigns a variable from (or returns) a call to the stdlib
// `list.fold` / `dict.fold` with an anonymous `_fn_def_N` callback.
fn fold_call_from(
  function: python.Expression,
  arguments: List(python.Field(python.Expression)),
  module_paths: option.Option(dict.Dict(String, String)),
) -> option.Option(FoldCall) {
  let path = case function {
    python.FieldAccess(python.ModuleRef(module), "fold") ->
      case module_paths {
        option.Some(paths) -> dict.get(paths, module)
        option.None -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  case path {
    Ok("gleam/list") | Ok("gleam/dict") ->
      case arguments {
        [
          python.UnlabelledField(collection),
          python.UnlabelledField(initial),
          python.UnlabelledField(python.Variable(callback)),
        ] ->
          option.Some(FoldCall(
            path: result.unwrap(path, ""),
            callback: callback,
            collection: collection,
            initial: initial,
          ))
        _ -> option.None
      }
    _ -> option.None
  }
}

// Finds the leftmost fold call anywhere inside an expression: either the
// expression itself is the fold (`WrapperRoot`), or the fold is nested in the
// arguments of an enclosing call (`WrapperArgument`). The statement value from
// a `use`-desugared recursion is typically `result.try_(list.fold(...), fn)`,
// where the fold sits one argument deep and would otherwise never be inlined.
fn find_fold_place(
  expression: python.Expression,
  module_paths: option.Option(dict.Dict(String, String)),
) -> option.Option(#(FoldCall, WrapperLocation)) {
  case expression {
    python.Call(function, arguments) ->
      case fold_call_from(function, arguments, module_paths) {
        option.Some(call) -> option.Some(#(call, WrapperRoot))
        option.None ->
          find_fold_in_arguments(function, arguments, 0, module_paths)
      }
    _ -> option.None
  }
}

fn find_fold_in_arguments(
  function: python.Expression,
  arguments: List(python.Field(python.Expression)),
  index: Int,
  module_paths: option.Option(dict.Dict(String, String)),
) -> option.Option(#(FoldCall, WrapperLocation)) {
  case arguments {
    [] ->
      find_fold_place(function, module_paths)
      |> option.map(fn(pair) {
        let #(call, location) = pair
        #(call, WrapperFunction(location))
      })
    [argument, ..rest] -> {
      let contained = case argument {
        python.UnlabelledField(item) -> find_fold_place(item, module_paths)
        python.LabelledField(_, item) -> find_fold_place(item, module_paths)
      }
      case contained {
        option.Some(pair) -> {
          let #(call, location) = pair
          option.Some(#(call, WrapperArgument(index, location)))
        }
        option.None ->
          find_fold_in_arguments(function, rest, index + 1, module_paths)
      }
    }
  }
}

// Rebuilds an expression with `replacement` standing in for the detected fold.
fn replace_fold_place(
  expression: python.Expression,
  location: WrapperLocation,
  replacement: python.Expression,
) -> python.Expression {
  case location {
    WrapperRoot -> replacement
    WrapperArgument(index, over) ->
      case expression {
        python.Call(function, arguments) ->
          python.Call(
            function,
            list.index_map(arguments, fn(field, call_index) {
              case call_index == index {
                True -> replace_field_place(field, over, replacement)
                False -> field
              }
            }),
          )
        _ -> expression
      }
    WrapperFunction(over) ->
      case expression {
        python.Call(function, arguments) ->
          python.Call(
            replace_fold_place(function, over, replacement),
            arguments,
          )
        _ -> expression
      }
  }
}

fn replace_field_place(
  field: python.Field(python.Expression),
  location: WrapperLocation,
  replacement: python.Expression,
) -> python.Field(python.Expression) {
  case field {
    python.UnlabelledField(item) ->
      python.UnlabelledField(replace_fold_place(item, location, replacement))
    python.LabelledField(label, item) ->
      python.LabelledField(
        label,
        replace_fold_place(item, location, replacement),
      )
  }
}

fn flatten_body_leaked(statements: List(python.Statement)) -> List(String) {
  list.flatten(list.map(statements, statement_leaked_names))
}

fn statement_leaked_names(statement: python.Statement) -> List(String) {
  case statement {
    python.SimpleAssignment(name, _) -> [name]
    python.MultipleAssignment(names, _) -> names
    python.Match(_, cases) ->
      list.flatten(
        list.map(cases, fn(match_case) {
          let python.MatchCase(pattern, _, body) = match_case
          list.append(pattern_binds(pattern), flatten_body_leaked(body))
        }),
      )
    python.While(_, body) -> flatten_body_leaked(body)
    python.If(_, body) -> flatten_body_leaked(body)
    python.For(_, _, body) -> flatten_body_leaked(body)
    python.FunctionDef(function) -> [function.name]
    python.Expression(_) | python.Return(_) -> []
  }
}

// Substitutes a set of renames throughout a statement tree, renaming every
// occurrence of a mapped name (references, binding targets, patterns, nested
// function names and parameters).
fn statement_substitute(
  statement: python.Statement,
  renames: dict.Dict(String, String),
) -> python.Statement {
  case statement {
    python.Expression(expression) ->
      python.Expression(expression_substitute(expression, renames))
    python.Return(expression) ->
      python.Return(expression_substitute(expression, renames))
    python.SimpleAssignment(name, value) ->
      python.SimpleAssignment(
        result.unwrap(dict.get(renames, name), name),
        expression_substitute(value, renames),
      )
    python.MultipleAssignment(names, value) ->
      python.MultipleAssignment(
        names
          |> list.map(fn(name) { result.unwrap(dict.get(renames, name), name) }),
        expression_substitute(value, renames),
      )
    python.Match(subject, cases) ->
      python.Match(
        subject: expression_substitute(subject, renames),
        cases: list.map(cases, fn(match_case) {
          let python.MatchCase(pattern, guard, body) = match_case
          python.MatchCase(
            pattern_substitute(pattern, renames),
            option.map(guard, expression_substitute(_, renames)),
            body |> list.map(fn(s) { statement_substitute(s, renames) }),
          )
        }),
      )
    python.While(condition, body) ->
      python.While(
        condition: expression_substitute(condition, renames),
        body: body |> list.map(fn(s) { statement_substitute(s, renames) }),
      )
    python.If(condition, body) ->
      python.If(
        condition: expression_substitute(condition, renames),
        body: body |> list.map(fn(s) { statement_substitute(s, renames) }),
      )
    python.For(targets, iterable, body) ->
      python.For(
        targets: targets
          |> list.map(fn(name) { result.unwrap(dict.get(renames, name), name) }),
        iterable: expression_substitute(iterable, renames),
        body: body |> list.map(fn(s) { statement_substitute(s, renames) }),
      )
    python.FunctionDef(function) ->
      python.FunctionDef(
        python.Function(
          ..function,
          name: result.unwrap(dict.get(renames, function.name), function.name),
          parameters: list.map(function.parameters, fn(parameter) {
            case parameter {
              python.NameParam(name) ->
                python.NameParam(result.unwrap(dict.get(renames, name), name))
              python.DiscardParam(_) -> parameter
            }
          }),
          body: function.body
            |> list.map(fn(s) { statement_substitute(s, renames) }),
        ),
      )
  }
}

fn expression_substitute(
  expression: python.Expression,
  renames: dict.Dict(String, String),
) -> python.Expression {
  case expression {
    python.Variable(name) ->
      python.Variable(result.unwrap(dict.get(renames, name), name))
    python.ModuleRef(_)
    | python.String(_)
    | python.Number(_)
    | python.Bool(_)
    | python.Nil
    | python.Dict(_) -> expression
    python.Tuple(elements) ->
      python.Tuple(list.map(elements, expression_substitute(_, renames)))
    python.Negate(inner) -> python.Negate(expression_substitute(inner, renames))
    python.Not(inner) -> python.Not(expression_substitute(inner, renames))
    python.Panic(inner) -> python.Panic(expression_substitute(inner, renames))
    python.Todo(inner) -> python.Todo(expression_substitute(inner, renames))
    python.Lambda(args, body) ->
      python.Lambda(
        args
          |> list.map(fn(arg) {
            case arg {
              python.Variable(name) ->
                python.Variable(result.unwrap(dict.get(renames, name), name))
              _ -> arg
            }
          }),
        expression_substitute(body, renames),
      )
    python.List(elements) ->
      python.List(list.map(elements, expression_substitute(_, renames)))
    python.ListWithRest(elements, rest) ->
      python.ListWithRest(
        list.map(elements, expression_substitute(_, renames)),
        expression_substitute(rest, renames),
      )
    python.TupleIndex(tuple, index) ->
      python.TupleIndex(expression_substitute(tuple, renames), index)
    python.FieldAccess(container, label) ->
      python.FieldAccess(expression_substitute(container, renames), label)
    python.Call(function, arguments) ->
      python.Call(
        expression_substitute(function, renames),
        list.map(arguments, fn(field) {
          case field {
            python.UnlabelledField(item) ->
              python.UnlabelledField(expression_substitute(item, renames))
            python.LabelledField(label, item) ->
              python.LabelledField(label, expression_substitute(item, renames))
          }
        }),
      )
    python.RecordUpdate(record, fields) ->
      python.RecordUpdate(
        expression_substitute(record, renames),
        list.map(fields, fn(field) {
          case field {
            python.UnlabelledField(item) ->
              python.UnlabelledField(expression_substitute(item, renames))
            python.LabelledField(label, item) ->
              python.LabelledField(label, expression_substitute(item, renames))
          }
        }),
      )
    python.BinaryOperator(operator, left, right) ->
      python.BinaryOperator(
        operator,
        expression_substitute(left, renames),
        expression_substitute(right, renames),
      )
    python.Slice(container, start, end) ->
      python.Slice(
        expression_substitute(container, renames),
        expression_substitute(start, renames),
        option.map(end, expression_substitute(_, renames)),
      )
    python.AssignmentExpression(name, value) ->
      python.AssignmentExpression(
        result.unwrap(dict.get(renames, name), name),
        expression_substitute(value, renames),
      )
    python.IsNotNone(inner) ->
      python.IsNotNone(expression_substitute(inner, renames))
    python.BitString(segments) ->
      python.BitString(
        list.map(segments, fn(segment) {
          let python.BitStringSegment(value, options) = segment
          python.BitStringSegment(
            expression_substitute(value, renames),
            options,
          )
        }),
      )
  }
}

fn pattern_substitute(
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
    python.PatternAssignment(pattern, name) ->
      python.PatternAssignment(
        pattern_substitute(pattern, renames),
        result.unwrap(dict.get(renames, name), name),
      )
    python.PatternTuple(value) ->
      python.PatternTuple(list.map(value, pattern_substitute(_, renames)))
    python.PatternList(elems, rest) ->
      python.PatternList(
        list.map(elems, pattern_substitute(_, renames)),
        option.map(rest, pattern_substitute(_, renames)),
      )
    python.PatternAlternate(patterns) ->
      python.PatternAlternate(
        list.map(patterns, pattern_substitute(_, renames)),
      )
    python.PatternConstructor(module, constructor, arguments) ->
      python.PatternConstructor(
        module,
        constructor,
        list.map(arguments, fn(field) {
          case field {
            python.UnlabelledField(item) ->
              python.UnlabelledField(pattern_substitute(item, renames))
            python.LabelledField(label, item) ->
              python.LabelledField(label, pattern_substitute(item, renames))
          }
        }),
      )
  }
}

// The loop-local variable names for a fold of a given module path, suffixed by
// the fold's `serial` so nested folds do not collide. These are only ever
// referenced inside the loop they are bound in, so they are added to the
// leaked set for the collision check (a callback body naming one accidentally
// would read a loop local instead of its own value).
fn fold_loop_names(path: String, serial: Int) -> List(String) {
  let FoldNames(list_name, acc_name, item_name, rest_name) =
    fold_names(path, serial)
  [list_name, acc_name, item_name, rest_name]
}

type FoldNames {
  FoldNames(
    // The name of the collection walk variable (the list being consumed or
    // the dict being iterated).
    list: String,
    // The accumulated result.
    acc: String,
    // The element/key being processed.
    item: String,
    // The remaining collection / value being processed.
    rest: String,
  )
}

fn fold_names(path: String, serial: Int) -> FoldNames {
  let suffix = case serial {
    0 -> ""
    _ -> "_" <> int.to_string(serial)
  }
  case path {
    "gleam/list" ->
      FoldNames(
        list: "_gleam_fold_list" <> suffix,
        acc: "_gleam_fold_acc" <> suffix,
        item: "_gleam_fold_item" <> suffix,
        rest: "_gleam_fold_rest" <> suffix,
      )
    "gleam/dict" ->
      FoldNames(
        list: "_gleam_fold_dict" <> suffix,
        acc: "_gleam_fold_acc" <> suffix,
        item: "_gleam_fold_key" <> suffix,
        rest: "_gleam_fold_value" <> suffix,
      )
    _ -> FoldNames("", "", "", "")
  }
}

// Builds the loop for a fold call, binding the callback's parameters to the
// loop locals and rewriting the callback body's returns into accumulator
// assignments. Returns `None` when the callback is unusable (e.g. a callback
// parameter count that does not match the fold's arity).
// The names of the anonymous callbacks of any `list.fold`/`dict.fold` call
// still present in a statement list. Their definitions must stay siblings of
// the calls so the recursive fold inline can find them.
fn fold_callback_names(statements: List(python.Statement)) -> List(String) {
  statements
  |> list.map(fold_callback_names_statement)
  |> list.flatten
  |> list.unique
}

fn fold_callback_names_statement(statement: python.Statement) -> List(String) {
  case statement {
    python.SimpleAssignment(_, value) | python.Return(value) ->
      fold_callback_names_expression(value)
    _ -> []
  }
}

fn fold_callback_names_expression(
  expression: python.Expression,
) -> List(String) {
  case expression {
    python.Call(python.FieldAccess(python.ModuleRef(_), "fold"), arguments) ->
      case arguments {
        [_, _, python.UnlabelledField(python.Variable(name))] -> [name]
        _ -> []
      }
    python.Call(function, arguments) ->
      fold_callback_names_expression(function)
      |> list.append(
        list.flatten(
          list.map(arguments, fn(field) {
            case field {
              python.UnlabelledField(item) ->
                fold_callback_names_expression(item)
              python.LabelledField(_, item) ->
                fold_callback_names_expression(item)
            }
          }),
        ),
      )
    _ -> []
  }
}

fn build_fold_loop(
  parameters: List(python.FunctionParameter),
  body: List(python.Statement),
  call: FoldCall,
  serial: Int,
  target: FoldTarget,
) -> option.Option(List(python.Statement)) {
  let names = fold_names(call.path, serial)
  let acc_name = names.acc
  let parameter_names =
    list.filter_map(parameters, fn(parameter) {
      case parameter {
        python.NameParam(name) -> Ok(name)
        python.DiscardParam(_) -> Error(Nil)
      }
    })
  // Nested functions defined by the callback body are pure closures: they
  // capture enclosing names by reference and are only ever *called* inside the
  // loop, never defined meaningfully per iteration. Hoisting them out of the
  // loop avoids re-creating the function object on every element. A definition
  // that is the callback of a `list.fold`/`dict.fold` call still in the body
  // is kept in place: the recursive fold inline needs the definition as a
  // sibling of its call.
  let fold_callback_names = fold_callback_names(body)
  let #(hoisted_defs, inline_body) =
    list.fold(body, #([], []), fn(acc, statement) {
      let #(defs, rest) = acc
      case statement {
        python.FunctionDef(function) ->
          case list.contains(fold_callback_names, function.name) {
            True -> #(defs, [statement, ..rest])
            False -> #([statement, ..defs], rest)
          }
        _ -> #(defs, [statement, ..rest])
      }
    })
  let hoisted_defs = list.reverse(hoisted_defs)
  let inline_body = list.reverse(inline_body)
  let loop = case call.path, parameter_names {
    "gleam/list", [acc_param, item_param] -> [
      python.SimpleAssignment(names.list, call.collection),
      python.SimpleAssignment(names.acc, call.initial),
      python.While(
        python.BinaryOperator(
          python.Is,
          python.Call(python.Variable("type"), [
            python.UnlabelledField(python.Variable(names.list)),
          ]),
          python.Variable("GleamList"),
        ),
        list.flatten([
          [
            python.SimpleAssignment(
              names.item,
              python.FieldAccess(python.Variable(names.list), "value"),
            ),
            python.SimpleAssignment(
              names.rest,
              python.FieldAccess(python.Variable(names.list), "tail"),
            ),
            python.SimpleAssignment(names.list, python.Variable(names.rest)),
            python.SimpleAssignment(acc_param, python.Variable(names.acc)),
            python.SimpleAssignment(item_param, python.Variable(names.item)),
          ],
          inline_body,
        ]),
      ),
    ]
    "gleam/dict", [acc_param, key_param, value_param] -> [
      python.SimpleAssignment(names.list, call.collection),
      python.SimpleAssignment(names.acc, call.initial),
      python.For(
        [names.item, names.rest],
        python.Call(
          python.FieldAccess(python.Variable(names.list), "items"),
          [],
        ),
        list.flatten([
          [
            python.SimpleAssignment(acc_param, python.Variable(names.acc)),
            python.SimpleAssignment(key_param, python.Variable(names.item)),
            python.SimpleAssignment(value_param, python.Variable(names.rest)),
          ],
          inline_body,
        ]),
      ),
    ]
    _, _ -> []
  }
  let loop = list.append(hoisted_defs, loop)
  let finish = case target {
    FoldAssign(target_names) ->
      case target_names {
        [name] -> [python.SimpleAssignment(name, python.Variable(acc_name))]
        _ -> [
          python.MultipleAssignment(target_names, python.Variable(acc_name)),
        ]
      }
    FoldReturn -> [python.Return(python.Variable(acc_name))]
    FoldTemp -> []
  }
  case loop {
    [] -> option.None
    _ -> option.Some(list.append(loop, finish))
  }
}

// Replaces `return <expr>` with `_gleam_fold_acc = <expr>` throughout a
// statement tree (so the spliced callback body feeds the accumulator), leaving
// nested function definitions untouched.
fn replace_statement_returns(
  statement: python.Statement,
  acc_name: String,
) -> python.Statement {
  case statement {
    python.Return(expression) -> python.SimpleAssignment(acc_name, expression)
    python.Match(subject, cases) ->
      python.Match(
        subject: subject,
        cases: list.map(cases, fn(match_case) {
          let python.MatchCase(pattern, guard, body) = match_case
          python.MatchCase(
            pattern,
            guard,
            body |> list.map(fn(s) { replace_statement_returns(s, acc_name) }),
          )
        }),
      )
    python.While(condition, body) ->
      python.While(
        condition: condition,
        body: body |> list.map(fn(s) { replace_statement_returns(s, acc_name) }),
      )
    python.If(condition, body) ->
      python.If(
        condition: condition,
        body: body |> list.map(fn(s) { replace_statement_returns(s, acc_name) }),
      )
    python.For(targets, iterable, body) ->
      python.For(
        targets: targets,
        iterable: iterable,
        body: body |> list.map(fn(s) { replace_statement_returns(s, acc_name) }),
      )
    python.FunctionDef(_) -> statement
    python.Expression(_)
    | python.SimpleAssignment(_, _)
    | python.MultipleAssignment(_, _) -> statement
  }
}

// Re-applies the fold inline in nested scopes (case bodies, loop bodies,
// nested function bodies) once no top-level fold can be inlined further. The
// `serial` is threaded through so each inlined fold in any nested scope gets a
// distinct set of loop-local names.
fn recurse_fold_scopes(
  statements: List(python.Statement),
  module_paths: option.Option(dict.Dict(String, String)),
  serial: Int,
  enclosing: List(python.Statement),
  _nested: Bool,
) -> #(List(python.Statement), Int) {
  list.fold(statements, #([], serial), fn(pair, statement) {
    let #(done, serial) = pair
    case statement {
      python.Match(subject, cases) -> {
        let #(rewritten_cases, next_serial) =
          list.fold(cases, #([], serial), fn(pair, match_case) {
            let #(folded_cases, serial) = pair
            let python.MatchCase(pattern, guard, body) = match_case
            let #(folded, next_serial) =
              inline_fold_scope(body, module_paths, serial, enclosing, True)
            #(
              list.append(folded_cases, [
                python.MatchCase(pattern, guard, folded),
              ]),
              next_serial,
            )
          })
        #(
          list.append(done, [
            python.Match(subject: subject, cases: rewritten_cases),
          ]),
          next_serial,
        )
      }
      python.While(condition, body) -> {
        let #(folded, next_serial) =
          inline_fold_scope(body, module_paths, serial, enclosing, True)
        #(
          list.append(done, [
            python.While(condition: condition, body: folded),
          ]),
          next_serial,
        )
      }
      python.If(condition, body) -> {
        let #(folded, next_serial) =
          inline_fold_scope(body, module_paths, serial, enclosing, True)
        #(
          list.append(done, [python.If(condition: condition, body: folded)]),
          next_serial,
        )
      }
      python.For(targets, iterable, body) -> {
        let #(folded, next_serial) =
          inline_fold_scope(body, module_paths, serial, enclosing, True)
        #(
          list.append(done, [
            python.For(targets: targets, iterable: iterable, body: folded),
          ]),
          next_serial,
        )
      }
      python.FunctionDef(function) -> {
        let #(folded, next_serial) =
          inline_fold_scope(
            function.body,
            module_paths,
            serial,
            enclosing,
            True,
          )
        #(
          list.append(done, [
            python.FunctionDef(python.Function(..function, body: folded)),
          ]),
          next_serial,
        )
      }
      _ -> #(list.append(done, [statement]), serial)
    }
  })
}
