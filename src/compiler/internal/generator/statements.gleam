import compiler/internal/generator as internal
import compiler/internal/generator/expressions
import compiler/python
import gleam/dict
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import gleam/string_tree.{type StringTree}
import glexer

pub fn generate_function(
  function: python.Function,
  field_names: dict.Dict(String, List(String)),
) -> StringTree {
  string_tree.new()
  |> string_tree.append_tree(internal.generate_comments(function.comments))
  |> string_tree.append("def ")
  |> string_tree.append(function.name |> internal.python_name)
  |> string_tree.append("(")
  |> string_tree.append_tree(internal.generate_plural(
    function.parameters,
    generate_parameter,
    ", ",
  ))
  |> string_tree.append("):\n")
  |> string_tree.append_tree(
    generate_function_body(function, field_names) |> internal.indent(4),
  )
}

// A docstring is emitted as the first statement of the body. A function whose
// body is otherwise empty emits just the docstring, not `pass`.
fn generate_function_body(
  function: python.Function,
  field_names: dict.Dict(String, List(String)),
) -> StringTree {
  case function.docstring, function.body {
    option.None, [] -> string_tree.from_string("pass")
    option.Some(_), [] -> internal.generate_docstring(function.docstring)
    option.None, _ -> generate_block(function.body, field_names)
    option.Some(_), _ ->
      internal.generate_docstring(function.docstring)
      |> string_tree.append("\n")
      |> string_tree.append_tree(generate_block(function.body, field_names))
  }
}

pub fn generate_module_header(
  docstring: option.Option(String),
  comments: List(String),
) -> StringTree {
  let header =
    internal.generate_comments(comments)
    |> string_tree.append_tree(internal.generate_docstring(docstring))
  case string_tree.is_empty(header) {
    True -> string_tree.new()
    False ->
      header
      |> string_tree.append(case docstring {
        option.None -> "\n"
        option.Some(_) -> "\n\n"
      })
  }
}

fn generate_parameter(param: python.FunctionParameter) -> StringTree {
  case param {
    python.NameParam(name) ->
      string_tree.from_string(name |> internal.python_name)
    python.DiscardParam(index) ->
      string_tree.from_string("_")
      |> string_tree.append(case index {
        0 -> ""
        idx -> idx |> int.to_string
      })
  }
}

pub fn generate_block(
  statements: List(python.Statement),
  field_names: dict.Dict(String, List(String)),
) -> StringTree {
  case statements {
    [] -> string_tree.from_string("pass")
    multiple_lines ->
      internal.generate_plural(
        multiple_lines,
        fn(statement) { generate_statement(statement, field_names) },
        "\n",
      )
  }
}

pub fn generate_statement(
  statement: python.Statement,
  field_names: dict.Dict(String, List(String)),
) -> StringTree {
  case statement {
    python.Expression(expression) -> expressions.generate_expression(expression)
    python.Return(expression) ->
      string_tree.from_string("return ")
      |> string_tree.append_tree(expressions.generate_expression(expression))
    python.SimpleAssignment(name, value) -> {
      string_tree.new()
      |> string_tree.append(name |> internal.python_name)
      |> string_tree.append(" = ")
      |> string_tree.append_tree(expressions.generate_expression(value))
    }
    python.MultipleAssignment(names, value) -> {
      case sequential_assignments(names, value) {
        option.Some(assignments) ->
          assignments
          |> list.map(fn(assignment) {
            generate_statement(assignment, field_names)
          })
          |> string_tree.join("\n")
        option.None ->
          string_tree.new()
          |> string_tree.append_tree(
            names
            |> list.map(fn(name) {
              name |> internal.python_name |> string_tree.from_string
            })
            |> string_tree.join(", "),
          )
          |> string_tree.append(" = ")
          |> string_tree.append_tree(expressions.generate_expression(value))
      }
    }
    python.Match(subject, cases) ->
      case bool_if_else(cases) {
        option.Some(#(true_body, false_body)) ->
          string_tree.new()
          |> string_tree.append("if ")
          |> string_tree.append_tree(expressions.generate_expression(subject))
          |> string_tree.append(":\n")
          |> string_tree.append_tree(
            generate_block(true_body, field_names) |> internal.indent(4),
          )
          |> string_tree.append("\nelse:\n")
          |> string_tree.append_tree(
            generate_block(false_body, field_names) |> internal.indent(4),
          )
        option.None ->
          case constructor_dispatch(subject, cases, field_names) {
            option.Some(chain) -> chain
            option.None ->
              string_tree.new()
              |> string_tree.append("match ")
              |> string_tree.append_tree(expressions.generate_expression(
                subject,
              ))
              |> string_tree.append(":\n")
              |> string_tree.append_tree(
                generate_cases(cases, field_names) |> internal.indent(4),
              )
          }
      }
    python.While(condition, body) ->
      string_tree.new()
      |> string_tree.append("while ")
      |> string_tree.append_tree(expressions.generate_expression(condition))
      |> string_tree.append(":\n")
      |> string_tree.append_tree(
        generate_block(body, field_names) |> internal.indent(4),
      )
    python.If(condition, body) ->
      string_tree.new()
      |> string_tree.append("if ")
      |> string_tree.append_tree(expressions.generate_expression(condition))
      |> string_tree.append(":\n")
      |> string_tree.append_tree(
        generate_block(body, field_names) |> internal.indent(4),
      )
    python.For(targets, iterable, body) ->
      string_tree.new()
      |> string_tree.append("for ")
      |> string_tree.append_tree(
        targets
        |> list.map(string_tree.from_string)
        |> internal.generate_plural(fn(tree) { tree }, ", "),
      )
      |> string_tree.append(" in ")
      |> string_tree.append_tree(expressions.generate_expression(iterable))
      |> string_tree.append(":\n")
      |> string_tree.append_tree(
        generate_block(body, field_names) |> internal.indent(4),
      )
    python.FunctionDef(function) -> generate_function(function, field_names)
  }
}

pub fn generate_constant(constant: python.Constant) -> StringTree {
  string_tree.new()
  |> string_tree.append_tree(internal.generate_comments(constant.comments))
  |> string_tree.append_tree(
    string_tree.from_string(constant.name |> internal.python_name)
    |> string_tree.append(" = ")
    |> string_tree.append_tree(expressions.generate_expression(constant.value)),
  )
}

fn generate_cases(
  cases: List(python.MatchCase),
  field_names: dict.Dict(String, List(String)),
) -> StringTree {
  case cases {
    [] -> string_tree.from_string("pass")
    cases ->
      internal.generate_plural(
        cases,
        fn(case_) { generate_case(case_, field_names) },
        "\n",
      )
  }
}

fn generate_case(
  case_: python.MatchCase,
  field_names: dict.Dict(String, List(String)),
) -> StringTree {
  string_tree.from_string("case ")
  |> string_tree.append_tree(generate_pattern(case_.pattern))
  |> string_tree.append_tree(generate_case_guard(case_.guard))
  |> string_tree.append(":\n")
  |> string_tree.append_tree(
    generate_block(case_.body, field_names) |> internal.indent(4),
  )
}

fn generate_pattern(pattern: python.Pattern) -> StringTree {
  case pattern {
    python.PatternWildcard -> string_tree.from_string("_")
    python.PatternInt(str) | python.PatternFloat(str) ->
      string_tree.from_string(expressions.python_number_literal(str))
    python.PatternVariable(str) ->
      string_tree.from_string(str |> internal.python_name)
    python.PatternString(str) ->
      case glexer.unescape_string(str) {
        Error(_) -> string_tree.from_strings(["\"", str, "\""])
        Ok(unescaped) ->
          string_tree.from_string(
            "\"" <> expressions.python_escape(unescaped) <> "\"",
          )
      }
    python.PatternAssignment(pattern, name) ->
      generate_pattern(pattern)
      |> string_tree.append(" as ")
      |> string_tree.append(name |> internal.python_name)
    python.PatternTuple(patterns) ->
      patterns
      |> list.map(generate_pattern)
      |> string_tree.join(", ")
      |> string_tree.prepend("(")
      |> string_tree.append(")")
    python.PatternList(elements, rest) -> generate_pattern_list(elements, rest)
    python.PatternAlternate(patterns) ->
      // Python requires every alternative to bind the same names. Named
      // discards (e.g. `_arg`) are rendered as `_`-prefixed variables by the
      // transformer, which would make Python reject the alternatives as
      // binding different names. Discards never bind a usable value, so they
      // are scrubbed to wildcards. Guard-carrying temps like
      // `_nested_subject_0` cannot appear inside an alternate (they force the
      // alternative into its own case), so any `_`-prefixed variable found
      // here is a discard.
      patterns
      |> list.map(fn(pattern) { pattern |> scrub_discards |> generate_pattern })
      |> string_tree.join(" | ")
    python.PatternConstructor(module, constructor, arguments) ->
      case constructor, arguments, module {
        // The Bool constructors are represented in the Python runtime by the
        // Python keywords `True` and `False`, so patterns referencing them
        // must not be rendered as constructor calls. The compiler's own
        // `python.Nil` AST node is a real value (`None`) whose nullary
        // pattern needs no class pattern.
        "True", [], _ -> string_tree.from_string("True")
        "False", [], _ -> string_tree.from_string("False")
        "Nil", [], option.None -> string_tree.from_string("None")
        // Nullary constructors are represented at runtime by an instance of
        // the constructor class (e.g. `File()`), so a pattern matches them
        // as a class pattern (isinstance check).
        _, _, _ ->
          module
          |> option.map(fn(mod) { string_tree.from_strings([mod, "."]) })
          |> option.unwrap(string_tree.new())
          |> string_tree.append(constructor |> internal.python_name)
          |> string_tree.append("(")
          |> string_tree.append_tree(internal.generate_plural(
            arguments,
            generate_pattern_constructor_field,
            ", ",
          ))
          |> string_tree.append(")")
      }
  }
}

fn generate_pattern_constructor_field(
  field: python.Field(python.Pattern),
) -> StringTree {
  case field {
    python.LabelledField(label, pattern) ->
      string_tree.from_strings([label |> internal.python_name, "="])
      |> string_tree.append_tree(generate_pattern(pattern))
    python.UnlabelledField(pattern) -> generate_pattern(pattern)
  }
}

// Replaces discarded variables (rendered as `_`-prefixed names by the
// transformer) with wildcards. Only safe inside a PatternAlternate, where
// guard-carrying temp variables can never appear.
fn scrub_discards(pattern: python.Pattern) -> python.Pattern {
  case pattern {
    python.PatternVariable(name) ->
      case name |> string.starts_with("_") {
        True -> python.PatternWildcard
        False -> python.PatternVariable(name)
      }
    python.PatternAssignment(inner, name) ->
      python.PatternAssignment(scrub_discards(inner), name)
    python.PatternTuple(patterns) ->
      patterns |> list.map(scrub_discards) |> python.PatternTuple
    python.PatternList(elements, rest) ->
      python.PatternList(
        list.map(elements, scrub_discards),
        rest |> option.map(scrub_discards),
      )
    python.PatternConstructor(module, constructor, arguments) ->
      python.PatternConstructor(
        module,
        constructor,
        list.map(arguments, fn(field) {
          case field {
            python.LabelledField(label, inner) ->
              python.LabelledField(label, scrub_discards(inner))
            python.UnlabelledField(inner) ->
              python.UnlabelledField(scrub_discards(inner))
          }
        }),
      )
    other -> other
  }
}

/// Lists are weird. Gleam syntax is like [a, b, c, ..rest]
/// But the pattern in python has to match a linked list.
/// The pattern is essentially GleamList(a, GleamList(b, GleamList(c, rest)))
/// potential optimization: make tail recursive by carrying the number of
/// closing parenns forward
fn generate_pattern_list(elements, rest) -> StringTree {
  case elements, rest {
    [], option.None -> string_tree.from_string("EmptyGleamList()")
    [], option.Some(pattern) -> generate_pattern(pattern)
    [head, ..others], rest ->
      string_tree.from_string("GleamList(")
      |> string_tree.append_tree(generate_pattern(head))
      |> string_tree.append(", ")
      |> string_tree.append_tree(generate_pattern_list(others, rest))
      |> string_tree.append(")")
  }
}

fn generate_case_guard(guard: option.Option(python.Expression)) -> StringTree {
  case guard {
    option.None -> string_tree.new()
    option.Some(expression) ->
      string_tree.from_string(" if ")
      |> string_tree.append_tree(expressions.generate_expression(expression))
  }
}

// A match on a boolean value with a True/False (or wildcard) case pair is
// emitted as a plain if/else, which is substantially faster than a Python
// match statement. Since Gleam has no if statement, every boolean branch in
// the source compiles through a match, so this affects all generated code.
// The subject is still evaluated exactly once by the if.
fn bool_if_else(
  cases: List(python.MatchCase),
) -> option.Option(#(List(python.Statement), List(python.Statement))) {
  case cases {
    [
      python.MatchCase(first_pattern, option.None, first_body),
      python.MatchCase(second_pattern, option.None, second_body),
    ] ->
      case pattern_is_true(first_pattern) {
        True ->
          case second_pattern {
            python.PatternConstructor(_, "False", []) ->
              option.Some(#(first_body, second_body))
            python.PatternWildcard -> option.Some(#(first_body, second_body))
            _ -> option.None
          }
        False ->
          case pattern_is_false(first_pattern), second_pattern {
            True, python.PatternConstructor(_, "True", []) ->
              option.Some(#(second_body, first_body))
            True, python.PatternWildcard ->
              option.Some(#(second_body, first_body))
            _, _ -> option.None
          }
      }
    _ -> option.None
  }
}

fn pattern_is_true(pattern: python.Pattern) -> Bool {
  case pattern {
    python.PatternConstructor(_, "True", []) -> True
    _ -> False
  }
}

fn pattern_is_false(pattern: python.Pattern) -> Bool {
  case pattern {
    python.PatternConstructor(_, "False", []) -> True
    _ -> False
  }
}

type ConstructorBranch {
  ConstructorBranch(
    // The runtime class the case matches, rendered with any module prefix.
    class: StringTree,
    // Name bindings produced by the case's fields, as statements.
    bindings: List(python.Statement),
    // Extra conditions a branch must satisfy, such as a field equal to a
    // literal (e.g. `GenericTypeVariable(name, True)`).
    conditions: List(python.Expression),
    body: List(python.Statement),
  )
}

// A match whose cases are all simple constructor patterns dispatches on the
// runtime class with `type(x) is T` chains, which is several times faster
// than a Python match statement. Constructor fields are read positionally;
// for the module's own types the field name is known at compile time and a
// plain attribute read is emitted, otherwise the runtime `__match_args__`
// tuple supplies the name. Returns None (the caller falls back to `match`)
// if any case is too complex: nested patterns, guards, alternates, or the
// True/False/None literals. Only simple subjects are reused, since repeating
// a call expression would evaluate it more than once.
fn constructor_dispatch(
  subject: python.Expression,
  cases: List(python.MatchCase),
  field_names: dict.Dict(String, List(String)),
) -> option.Option(StringTree) {
  case subject {
    python.Variable(_) | python.FieldAccess(_, _) ->
      case constructor_branches(subject, cases, field_names) {
        option.None -> option.None
        option.Some(#(branches, else_body)) ->
          option.Some(generate_constructor_chain(
            subject,
            branches,
            else_body,
            field_names,
          ))
      }
    _ -> option.None
  }
}

fn constructor_branches(
  subject: python.Expression,
  cases: List(python.MatchCase),
  field_names: dict.Dict(String, List(String)),
) -> option.Option(
  #(List(ConstructorBranch), option.Option(List(python.Statement))),
) {
  case cases {
    [] -> option.None
    _ -> {
      let #(branches, else_body, ok) =
        cases
        |> list.fold(#([], option.None, True), fn(state, case_) {
          let #(branches, else_body, ok) = state
          case ok {
            False -> state
            True ->
              case case_ {
                python.MatchCase(pattern, option.None, body) ->
                  case pattern {
                    python.PatternWildcard ->
                      case else_body {
                        // A wildcard ends the chain; anything after it is
                        // unreachable, so reject rather than mis-order.
                        option.None -> #(branches, option.Some(body), True)
                        option.Some(_) -> #(branches, else_body, False)
                      }
                    python.PatternConstructor(module, name, arguments) ->
                      case
                        constructor_branch(
                          subject,
                          module,
                          name,
                          arguments,
                          body,
                          field_names,
                        )
                      {
                        option.Some(branch) -> #(
                          list.append(branches, [branch]),
                          else_body,
                          True,
                        )
                        option.None -> #(branches, else_body, False)
                      }
                    _ -> #(branches, else_body, False)
                  }
                _ -> #(branches, else_body, False)
              }
          }
        })
      case ok {
        True ->
          case list.is_empty(branches) {
            True -> option.None
            False -> option.Some(#(branches, else_body))
          }
        False -> option.None
      }
    }
  }
}

fn constructor_branch(
  subject: python.Expression,
  module: option.Option(String),
  name: String,
  arguments: List(python.Field(python.Pattern)),
  body: List(python.Statement),
  field_names: dict.Dict(String, List(String)),
) -> option.Option(ConstructorBranch) {
  // The True/False/None constructors are the Python literals, and the Nil
  // constructor is a literal when unqualified; those are not classes.
  case name {
    "True" -> option.None
    "False" -> option.None
    "None" -> option.None
    "Nil" ->
      case module {
        option.None -> option.None
        option.Some(_) ->
          build_constructor_branch(
            subject,
            module,
            name,
            arguments,
            body,
            field_names,
          )
      }
    _ ->
      build_constructor_branch(
        subject,
        module,
        name,
        arguments,
        body,
        field_names,
      )
  }
}

fn build_constructor_branch(
  subject: python.Expression,
  module: option.Option(String),
  name: String,
  arguments: List(python.Field(python.Pattern)),
  body: List(python.Statement),
  field_names: dict.Dict(String, List(String)),
) -> option.Option(ConstructorBranch) {
  case list.all(arguments, argument_is_simple) {
    False -> option.None
    True -> {
      let class =
        module
        |> option.map(fn(mod) { mod <> "." })
        |> option.unwrap("")
        |> string_tree.from_string
        |> string_tree.append(name)
      let #(bindings, conditions) =
        arguments
        |> list.index_fold(#([], []), fn(acc, argument, index) {
          let #(bindings, conditions) = acc
          case argument {
            python.UnlabelledField(python.PatternVariable(bound)) -> #(
              list.append(bindings, [
                python.SimpleAssignment(
                  bound,
                  constructor_field(subject, module, name, index, field_names),
                ),
              ]),
              conditions,
            )
            python.UnlabelledField(python.PatternConstructor(_, literal, [])) ->
              case literal {
                "True" | "False" -> #(
                  bindings,
                  list.append(conditions, [
                    python.BinaryOperator(
                      python.Equal,
                      constructor_field(
                        subject,
                        module,
                        name,
                        index,
                        field_names,
                      ),
                      python.Bool(literal),
                    ),
                  ]),
                )
                _ -> acc
              }
            _ -> acc
          }
        })
      option.Some(ConstructorBranch(class, bindings, conditions, body))
    }
  }
}

// Reads the i-th constructor field of a matched value. An unqualified
// reference to one of the module's own constructors has a known field name;
// a qualified reference (`types.CallableType`, `option.Some`) is looked up
// through the package-wide field map. Either way a plain attribute read is
// emitted; unknown constructors fall back to the runtime `__match_args__`
// tuple.
fn constructor_field(
  subject: python.Expression,
  module: option.Option(String),
  constructor: String,
  index: Int,
  field_names: dict.Dict(String, List(String)),
) -> python.Expression {
  let names = case module {
    option.None -> dict.get(field_names, constructor)
    option.Some(binding) -> dict.get(field_names, binding <> "." <> constructor)
  }
  case names {
    Ok(all_names) ->
      case nth(all_names, index) {
        Ok(name) -> python.FieldAccess(subject, name)
        Error(_) -> getattr_field(subject, index)
      }
    Error(_) -> getattr_field(subject, index)
  }
}

// The i-th element of a list, or Error if the list is shorter. Constructor
// field lists are tiny, so a linear scan is fine.
fn nth(list: List(String), index: Int) -> Result(String, Nil) {
  list
  |> list.index_fold(Error(Nil), fn(acc, item, i) {
    case i == index {
      True -> Ok(item)
      False -> acc
    }
  })
}

// Reads the i-th constructor field of a matched value positionally. The field
// name comes from the runtime `__match_args__`, so the generator need not know
// each constructor's field names.
fn getattr_field(subject: python.Expression, index: Int) -> python.Expression {
  python.Call(python.Variable("getattr"), [
    python.UnlabelledField(subject),
    python.UnlabelledField(python.TupleIndex(
      python.FieldAccess(subject, "__match_args__"),
      index,
    )),
  ])
}

fn argument_is_simple(argument: python.Field(python.Pattern)) -> Bool {
  case argument {
    python.UnlabelledField(python.PatternVariable(_)) -> True
    python.UnlabelledField(python.PatternWildcard) -> True
    // A field matched against the `True`/`False` literal (e.g. a
    // `GenericTypeVariable(name, True)` case) is simple: it compiles to a
    // field-equality condition rather than a Python pattern.
    python.UnlabelledField(python.PatternConstructor(_, "True", [])) -> True
    python.UnlabelledField(python.PatternConstructor(_, "False", [])) -> True
    _ -> False
  }
}

fn generate_constructor_chain(
  subject: python.Expression,
  branches: List(ConstructorBranch),
  else_body: option.Option(List(python.Statement)),
  field_names: dict.Dict(String, List(String)),
) -> StringTree {
  let chain =
    branches
    |> list.index_fold(string_tree.new(), fn(acc, branch, index) {
      let keyword = case index {
        0 -> "if"
        _ -> "elif"
      }
      let subject_tree = expressions.generate_expression(subject)
      let class_and_conditions =
        branch.conditions
        |> list.fold(branch.class, fn(tree, condition) {
          tree
          |> string_tree.append(" and ")
          |> string_tree.append_tree(expressions.generate_expression(condition))
        })
      let body_tree =
        branch.bindings
        |> list.append(branch.body)
        |> generate_block(field_names)
        |> internal.indent(4)
      acc
      |> internal.append_if_not_empty("\n")
      |> string_tree.append(keyword)
      |> string_tree.append(" type(")
      |> string_tree.append_tree(subject_tree)
      |> string_tree.append(") is ")
      |> string_tree.append_tree(class_and_conditions)
      |> string_tree.append(":\n")
      |> string_tree.append_tree(body_tree)
    })
  case else_body {
    option.None -> chain
    option.Some(body) ->
      chain
      |> internal.append_if_not_empty("\n")
      |> string_tree.append("else:\n")
      |> string_tree.append_tree(
        generate_block(body, field_names) |> internal.indent(4),
      )
  }
}

// A multiple assignment whose right-hand side is a tuple can be emitted as a
// sequence of single assignments, avoiding a per-iteration tuple allocation
// in the tail-recursive loop rebinds (`list, initial, fun = (rest, ...)`)
// that every list fold compiles to. Simultaneous semantics are preserved as
// long as each right-hand element reads only names that are not assigned
// earlier in the sequence: those still hold their old values.
fn sequential_assignments(
  names: List(String),
  value: python.Expression,
) -> option.Option(List(python.Statement)) {
  case value {
    python.Tuple(elements) ->
      case list.length(names) == list.length(elements) {
        False -> option.None
        True ->
          case
            list.index_fold(elements, True, fn(acc, element, index) {
              case acc {
                False -> False
                True -> {
                  let earlier = list.take(names, index)
                  let referenced = expression_refs(element)
                  list.all(earlier, fn(name) {
                    !list.contains(referenced, name)
                  })
                }
              }
            })
          {
            False -> option.None
            True ->
              case
                list.zip(names, elements)
                |> list.map(fn(pair) { python.SimpleAssignment(pair.0, pair.1) })
                |> list.filter(fn(assignment) {
                  case assignment {
                    python.SimpleAssignment(name, python.Variable(other)) ->
                      name != other
                    _ -> True
                  }
                })
              {
                // Every element was a no-op self-assignment (e.g. a driver
                // loop's `toml, = (toml,)`); emitting nothing would leave an
                // empty case body, so keep the tuple form instead.
                [] -> option.None
                assignments -> option.Some(assignments)
              }
          }
      }
    _ -> option.None
  }
}

// The variable names an expression reads, used to decide whether a multiple
// assignment can be split into sequential single assignments. A lambda's
// body is not read when the lambda is created, so it contributes nothing.
fn expression_refs(expression: python.Expression) -> List(String) {
  case expression {
    python.String(_) | python.Number(_) | python.Bool(_) | python.Nil -> []
    python.Variable(name) -> [name]
    python.ModuleRef(_) -> []
    python.Tuple(elements) -> list.flat_map(elements, expression_refs)
    python.Negate(inner) -> expression_refs(inner)
    python.Not(inner) -> expression_refs(inner)
    python.Panic(inner) -> expression_refs(inner)
    python.Todo(inner) -> expression_refs(inner)
    python.Lambda(_, _) -> []
    python.List(elements) -> list.flat_map(elements, expression_refs)
    python.ListWithRest(elements, rest) ->
      list.flat_map(elements, expression_refs)
      |> list.append(expression_refs(rest))
    python.TupleIndex(tuple, _) -> expression_refs(tuple)
    python.FieldAccess(container, _) -> expression_refs(container)
    python.Call(function, arguments) ->
      expression_refs(function)
      |> list.append(list.flat_map(arguments, field_refs))
    python.RecordUpdate(record, fields) ->
      expression_refs(record)
      |> list.append(list.flat_map(fields, field_refs))
    python.BinaryOperator(_, left, right) ->
      list.append(expression_refs(left), expression_refs(right))
    python.Slice(container, start, end) ->
      list.append(
        expression_refs(container),
        list.append(
          expression_refs(start),
          end |> option.map(expression_refs) |> option.unwrap([]),
        ),
      )
    python.AssignmentExpression(_, value) -> expression_refs(value)
    python.IsNotNone(inner) -> expression_refs(inner)
    python.BitString(segments) ->
      list.flat_map(segments, fn(segment) {
        list.append(
          expression_refs(segment.value),
          list.flat_map(segment.options, fn(option) {
            case option {
              python.SizeValueOption(size) -> expression_refs(size)
              _ -> []
            }
          }),
        )
      })
    python.Dict(pairs) ->
      list.flat_map(pairs, fn(pair) { expression_refs(pair.1) })
  }
}

fn field_refs(field: python.Field(python.Expression)) -> List(String) {
  case field {
    python.UnlabelledField(expression) -> expression_refs(expression)
    python.LabelledField(_, expression) -> expression_refs(expression)
  }
}
