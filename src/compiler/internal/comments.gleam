import gleam/dict
import gleam/list
import gleam/option
import gleam/string
import glexer
import glexer/token

/// The kind of a Gleam comment.
pub type Kind {
  /// A `//` comment.
  Normal
  /// A `///` documentation comment.
  Doc
  /// A `////` module documentation comment.
  Module
}

pub type Comment {
  Comment(kind: Kind, text: String, byte_offset: Int)
}

pub type Spanned {
  Spanned(start: Int, end: Int)
}

/// Lex the source with comments preserved and return every comment, in source
/// order. Comment tokens carry the text after the `//` markers (including any
/// leading space) and the byte offset of the first slash.
pub fn extract(source: String) -> List(Comment) {
  source
  |> glexer.new
  |> glexer.discard_whitespace
  |> glexer.lex
  |> list.filter_map(fn(pair) {
    case pair {
      #(token.CommentNormal(text), position) ->
        Ok(Comment(Normal, text, position.byte_offset))
      #(token.CommentDoc(text), position) ->
        Ok(Comment(Doc, text, position.byte_offset))
      #(token.CommentModule(text), position) ->
        Ok(Comment(Module, text, position.byte_offset))
      _ -> Error(Nil)
    }
  })
}

/// Given every top-level definition span in source order, distribute the
/// module's comments into three buckets: comments before the first definition
/// (module-level `////` and `//` comments; `///` docs are attached to that
/// first definition), comments preceding each later definition (keyed by that
/// definition's start byte offset), and comments after the last definition.
/// Comments that fall inside a definition's own span are dropped.
pub fn assign_leading_comments(
  spans: List(Spanned),
  comments: List(Comment),
) -> #(List(Comment), dict.Dict(Int, List(Comment)), List(Comment)) {
  case spans {
    [] -> #(comments, dict.new(), [])
    [first, ..rest] -> {
      let #(before_first, remaining) =
        split_while(comments, fn(c) { c.byte_offset < first.start })
      // `///` docs before the first definition document it; `////` and `//`
      // comments before it are module-level.
      let #(first_docs, module_comments) =
        list.partition(before_first, fn(c) { c.kind == Doc })
      let #(by_start, trailing) =
        assign_remaining(first.end, rest, remaining, dict.new())
      #(
        module_comments,
        dict.insert(by_start, first.start, first_docs),
        trailing,
      )
    }
  }
}

fn assign_remaining(
  previous_end: Int,
  spans: List(Spanned),
  comments: List(Comment),
  acc: dict.Dict(Int, List(Comment)),
) -> #(dict.Dict(Int, List(Comment)), List(Comment)) {
  case spans {
    [] -> #(acc, comments)
    [span, ..rest] -> {
      let comments =
        list.drop_while(comments, fn(c) { c.byte_offset <= previous_end })
      let #(leading, remaining) =
        split_while(comments, fn(c) { c.byte_offset < span.start })
      assign_remaining(
        span.end,
        rest,
        remaining,
        dict.insert(acc, span.start, leading),
      )
    }
  }
}

/// The docstring text from a list of comments: documentation and module
/// comments joined by newlines with surrounding whitespace trimmed.
pub fn docstring(comments: List(Comment)) -> option.Option(String) {
  let docs =
    comments
    |> list.filter_map(fn(comment) {
      case comment.kind {
        Doc | Module -> Ok(comment.text |> string.trim)
        Normal -> Error(Nil)
      }
    })
  case docs {
    [] -> option.None
    docs -> option.Some(string.join(docs, "\n"))
  }
}

/// The rendered `#` comment lines from a list of comments: regular comments
/// keep their text, so a `// note` becomes `# note`.
pub fn comment_lines(comments: List(Comment)) -> List(String) {
  list.filter_map(comments, fn(comment) {
    case comment.kind {
      Normal -> Ok(comment.text)
      Doc | Module -> Error(Nil)
    }
  })
}

/// All comments as `#` lines regardless of kind. Used for constants, which
/// have no docstring form in Python.
pub fn comment_texts(comments: List(Comment)) -> List(String) {
  list.map(comments, fn(comment) { comment.text })
}

fn split_while(
  items: List(a),
  predicate: fn(a) -> Bool,
) -> #(List(a), List(a)) {
  #(list.take_while(items, predicate), list.drop_while(items, predicate))
}
