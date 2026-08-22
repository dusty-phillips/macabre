import compiler
import glance
import gleam/string

pub fn list_fold_inline_test() {
  let assert Ok(module) =
    "import gleam/list

    pub fn add_all(numbers: List(Int), extra: Int) -> Int {
      numbers
      |> list.fold(0, fn(acc, n) { acc + n + extra })
    }
    "
    |> glance.module
  let output = compiler.compile_module(module)
  assert string.contains(output, "_gleam_fold_list")
  assert string.contains(output, "while type(_gleam_fold_list) is GleamList:")
  assert string.contains(output, "_gleam_fold_acc = acc + n + extra")
}

pub fn dict_fold_inline_test() {
  let assert Ok(module) =
    "import gleam/dict

    pub fn total(entries: Dict(String, Int)) -> Int {
      dict.fold(entries, 0, fn(acc, key, value) { acc + value })
    }
    "
    |> glance.module
  let output = compiler.compile_module(module)
  assert string.contains(output, "_gleam_fold_dict")
  assert string.contains(
    output,
    "for _gleam_fold_key, _gleam_fold_value in _gleam_fold_dict.items():",
  )
}

pub fn fold_callback_parameter_collision_test() {
  let assert Ok(module) =
    "import gleam/list

    pub fn sum_with(numbers: List(Int)) -> Int {
      let items = numbers
      list.fold(items, 2, fn(acc, items) { acc + items })
    }
    "
    |> glance.module
  let output = compiler.compile_module(module)
  assert string.contains(output, "items_gleam_fold = _gleam_fold_item")
}

// A fold whose callback contains another fold must not let the inner loop
// clobber the outer one's accumulator mid-iteration. Folds whose callbacks
// involve closures over the callback's own parameters stay in closure form,
// which isolates each fold's `_gleam_fold_*` locals in its own function scope;
// only closure-free callbacks are spliced into shared loops.
pub fn nested_folds_do_not_clobber_each_other_test() {
  let assert Ok(module) =
    "import gleam/list

    pub fn nested(numbers: List(Int), per_group: List(Int)) -> Int {
      list.fold(numbers, 0, fn(acc, n) {
        list.fold(per_group, acc + n, fn(acc, m) { acc + m })
      })
    }
    "
    |> glance.module
  let output = compiler.compile_module(module)
  // Folds inside nested scopes (a callback body, a case arm, an if/while/for
  // body) are never inlined — their per-iteration rebinding could clobber
  // same-named variables referenced after the block — so neither fold here
  // is inlined and no loop-local names are introduced at all.
  assert !string.contains(output, "_gleam_fold")
  assert string.contains(output, "return list.fold(numbers, 0, _fn_def_0)")
  assert string.contains(
    output,
    "return list.fold(per_group, acc + n, _fn_def_0)",
  )
}
