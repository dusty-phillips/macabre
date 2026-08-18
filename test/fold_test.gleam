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

// A fold whose callback contains another fold must give the inner one a
// distinct set of loop-local names and parameter bindings, or the inner loop
// clobbers the outer loop's `_gleam_fold_*` accumulator mid-iteration.
pub fn nested_folds_do_not_clobber_each_other_test() {
  let assert Ok(module) =
    "import gleam/list

    pub fn nested(numbers: List(Int), per_group: List(Int)) -> Int {
      list.fold(numbers, 0, fn(acc, n) {
        list.fold(per_group, acc, fn(acc, m) { acc + n + m })
      })
    }
    "
    |> glance.module
  let output = compiler.compile_module(module)
  assert string.contains(output, "_gleam_fold_list")
  assert string.contains(output, "_gleam_fold_acc_1")
  assert string.contains(output, "_gleam_fold_acc_1 = acc_gleam_fold + n + m")
}
