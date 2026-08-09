import compiler
import compiler/internal/comments
import glance
import gleam/dict

fn compile(source: String) -> String {
  let assert Ok(module) = glance.module(source)
  compiler.compile_module_with_comments(
    module,
    dict.new(),
    dict.new(),
    [],
    [],
    comments.extract(source),
  )
}

pub fn module_docs_and_comments_test() {
  assert compile(
      "
//// This module does things.
//// On two lines.

// A regular top comment.

/// Docs for foo.
// A note about foo.
pub fn foo() -> Int {
  1
}

/// Docs for a constant.
const answer = 42
",
    )
    == "from __future__ import annotations\nfrom gleam_builtins import *\n\n# A regular top comment.\n# A note about foo.\n\"\"\"This module does things.\nOn two lines.\"\"\"\n\ndef foo():\n    \"\"\"Docs for foo.\"\"\"\n    return 1\n\n\n# Docs for a constant.\nanswer = 42\n\n"
}

pub fn custom_type_doc_test() {
  assert compile(
      "
//// Module docs.

/// A type with docs.
pub type Person {
  Person(name: String, age: Int)
}
",
    )
    == "from __future__ import annotations\nfrom gleam_builtins import *\n\n\"\"\"Module docs.\"\"\"\n\n@dataclasses.dataclass(frozen=True)\nclass Person:\n    \"\"\"A type with docs.\"\"\"\n    name: str\n    age: int\n\n\n"
}

pub fn multi_variant_type_doc_test() {
  assert compile(
      "
//// Module docs.

/// A type with docs.
pub type Shape {
  Circle(radius: Float)
  Square(side: Int)
}
",
    )
    == "from __future__ import annotations\nfrom gleam_builtins import *\n\n\"\"\"Module docs.\"\"\"\n\n@dataclasses.dataclass(frozen=True)\nclass Circle:\n    \"\"\"A type with docs.\"\"\"\n    radius: Float\n\n@dataclasses.dataclass(frozen=True)\nclass Square:\n    side: int\n\n\n"
}

pub fn empty_body_docstring_test() {
  assert compile(
      "
//// Module docs.

/// Only docs, no body.
pub fn doc_only() -> Nil {}
",
    )
    == "from __future__ import annotations\nfrom gleam_builtins import *\n\n\"\"\"Module docs.\"\"\"\n\ndef doc_only():\n    \"\"\"Only docs, no body.\"\"\""
}

pub fn interior_comments_dropped_test() {
  assert compile(
      "
pub fn foo() -> Int {
  // inside the body, this is dropped
  1
}

// Between functions.
/// Docs for bar.
pub fn bar() -> Int {
  2
}
",
    )
    == "from __future__ import annotations\nfrom gleam_builtins import *\n\ndef foo():\n    return 1\n\n\n# Between functions.\ndef bar():\n    \"\"\"Docs for bar.\"\"\"\n    return 2"
}

pub fn comments_only_header_test() {
  assert compile(
      "
// Copyright 2026 Someone.
// All rights reserved.

pub fn main() -> Nil {}
",
    )
    == "from __future__ import annotations\nfrom gleam_builtins import *\n\n# Copyright 2026 Someone.\n# All rights reserved.\n\ndef main():\n    pass"
}

pub fn multi_line_doc_test() {
  assert compile(
      "
/// Line one.
/// Line two.
pub fn foo() -> Int {
  1
}
",
    )
    == "from __future__ import annotations\nfrom gleam_builtins import *\n\ndef foo():\n    \"\"\"Line one.\n    Line two.\"\"\"\n    return 1"
}

pub fn docstring_backslash_escape_test() {
  assert compile(
      "
/// Uses \\uXXXX escapes.
pub fn foo() -> Int {
  1
}
",
    )
    == "from __future__ import annotations\nfrom gleam_builtins import *\n\ndef foo():\n    \"\"\"Uses \\\\uXXXX escapes.\"\"\"\n    return 1"
}

pub fn no_comments_regression_test() {
  assert compile(
      "
pub fn foo() -> Int {
  1
}
",
    )
    == "from __future__ import annotations\nfrom gleam_builtins import *\n\ndef foo():\n    return 1"
}
