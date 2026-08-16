import errors
import filepath
import filesystem
import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import shellout
import simplifile

/// Name of the per-project stamp file recording which (repo, ref) pairs have
/// already been fetched and reset to, and the commit they are at. It lives in
/// the same directory as the clones (build/packages).
const stamp_file_name = ".macabre-refs"

/// How long, in seconds, a branch ref is considered fresh after being fetched.
/// Pinned commit refs never expire.
const ttl_seconds = 600

pub fn clone(
  name: String,
  repo: String,
  git_ref: String,
  from_dir: String,
) -> Result(Nil, errors.Error) {
  let clone_dir = filepath.join(from_dir, name)
  let stamp_file = filepath.join(from_dir, stamp_file_name)
  let now = unix_now()
  case is_git_checkout(clone_dir) {
    True -> {
      // An existing clone: just update it to the requested ref rather than
      // re-cloning the whole repository.
      case already_fetched(repo, git_ref, clone_dir, stamp_file, now) {
        True -> Ok(Nil)
        False -> {
          use _ <- result.try(
            shellout.command("git", ["fetch", "origin", git_ref], clone_dir, [])
            |> result.map_error(errors.GitCloneError(name, _)),
          )
          use _ <- result.try(
            shellout.command(
              "git",
              ["reset", "--hard", "FETCH_HEAD"],
              clone_dir,
              [],
            )
            |> result.map_error(errors.GitCloneError(name, _)),
          )
          stamp_head(repo, git_ref, clone_dir, stamp_file, name, now)
        }
      }
    }
    False -> {
      // A directory left over from a non-git resolution (e.g. a hex tarball
      // download) is not a clone. Removing it is required anyway for `git
      // clone` to succeed, and it must not be fetched into: git would walk up
      // the parent chain to an enclosing repository's `.git` and reset that
      // repo instead.
      case simplifile.is_directory(clone_dir) {
        Ok(True) -> filesystem.delete(clone_dir)
        _ -> Ok(Nil)
      }
      |> result.try(fn(_) {
        shellout.command("git", ["clone", repo, name], from_dir, [])
        |> result.map_error(errors.GitCloneError(name, _))
      })
      |> result.try(fn(_) {
        shellout.command("git", ["checkout", git_ref], clone_dir, [])
        |> result.map_error(errors.GitCheckoutError(name, git_ref, _))
        |> result.replace(Nil)
      })
      |> result.try(fn(_) {
        stamp_head(repo, git_ref, clone_dir, stamp_file, name, now)
      })
    }
  }
}

/// Whether we can skip fetching `git_ref` for `repo`: the stamp records that we
/// fetched it, the clone is still sitting at that commit, and the ref is either
/// pinned to an exact commit (a manifest `commit` entry, never expires) or was
/// fetched within the TTL. Branch refs older than the TTL are fetched so they
/// stay fresh.
fn already_fetched(
  repo: String,
  git_ref: String,
  clone_dir: String,
  stamp_file: String,
  now: Result(Int, #(Int, String)),
) -> Bool {
  case is_pinned_sha(git_ref) {
    False ->
      case now {
        // No clock available: can't tell how old the fetch is, so fetch.
        Error(_) -> False
        Ok(now) -> {
          let stale = fn(fetched) { now - fetched >= ttl_seconds }
          stamp_satisfies(repo, git_ref, clone_dir, stamp_file, stale)
        }
      }
    True ->
      stamp_satisfies(repo, git_ref, clone_dir, stamp_file, fn(_) { False })
  }
}

/// Look up the stamp for `repo|git_ref` and check that the clone's HEAD is the
/// stamped commit AND the stamp is not stale. `is_stale` receives the fetch
/// time from the stamp and decides whether it has expired.
fn stamp_satisfies(
  repo: String,
  git_ref: String,
  clone_dir: String,
  stamp_file: String,
  is_stale: fn(Int) -> Bool,
) -> Bool {
  case read_stamps(stamp_file) {
    Error(_) -> False
    Ok(stamps) ->
      case dict.get(stamps, ref_key(repo, git_ref)) {
        Error(_) -> False
        Ok(stamped) ->
          case head_sha(clone_dir) {
            Error(_) -> False
            Ok(head) ->
              head == stamped.sha && is_stale(stamped.fetched) == False
          }
      }
  }
}

/// Record the clone's current HEAD commit for `repo` at `git_ref`, so future
/// runs can skip the fetch. Both pinned and branch refs are recorded; the TTL
/// decides when a branch ref becomes stale.
fn stamp_head(
  repo: String,
  git_ref: String,
  clone_dir: String,
  stamp_file: String,
  name: String,
  now: Result(Int, #(Int, String)),
) -> Result(Nil, errors.Error) {
  use sha <- result.try(
    head_sha(clone_dir)
    |> result.map_error(fn(_) {
      errors.GitCloneError(name, #(-1, "rev-parse failed"))
    }),
  )
  use stamps <- result.try(read_stamps(stamp_file))
  let fetched = case now {
    Ok(t) -> t
    Error(_) -> -1
  }
  let stamps =
    dict.insert(
      stamps,
      ref_key(repo, git_ref),
      Stamp(sha: sha, fetched: fetched),
    )
  let contents =
    dict.fold(stamps, "", fn(acc, key, stamp) {
      acc
      <> key
      <> " "
      <> stamp.sha
      <> " "
      <> int.to_string(stamp.fetched)
      <> "\n"
    })
  filesystem.write(contents, stamp_file)
}

/// A commit SHA is 40 lowercase hex digits. Anything else (a branch name, a
/// tag, a ref) moves.
fn is_pinned_sha(git_ref: String) -> Bool {
  let hex = "0123456789abcdef"
  string.length(git_ref) == 40
  && {
    string.to_graphemes(git_ref)
    |> list.all(fn(char) { string.contains(hex, char) })
  }
}

/// A stamp entry: the commit a clone is at and the unix time it was fetched
/// (or reset to) at. `-1` means the time is unknown.
type Stamp {
  Stamp(sha: String, fetched: Int)
}

/// The current unix time in seconds, so branch-ref stamps can expire. Uses the
/// system `date` utility (available wherever `git` is). A failure to get the
/// time only disables the TTL shortcut, never the fetch itself.
fn unix_now() -> Result(Int, #(Int, String)) {
  case shellout.command("date", ["+%s"], ".", []) {
    Error(error) -> Error(error)
    Ok(line) ->
      case int.parse(string.trim(line)) {
        Ok(seconds) -> Ok(seconds)
        Error(_) -> Error(#(-1, "unparseable date output"))
      }
  }
}

fn ref_key(repo: String, git_ref: String) -> String {
  repo <> "|" <> git_ref
}

/// The current HEAD commit SHA of a checkout.
fn head_sha(clone_dir: String) -> Result(String, #(Int, String)) {
  shellout.command("git", ["rev-parse", "HEAD"], clone_dir, [])
  |> result.map(string.trim)
}

/// Read the stamp file into a dict of `repo|ref -> Stamp`. A missing file is an
/// empty dict. Lines that fail to parse are skipped.
fn read_stamps(
  stamp_file: String,
) -> Result(dict.Dict(String, Stamp), errors.Error) {
  case simplifile.read(stamp_file) {
    Error(simplifile.Enoent) -> Ok(dict.new())
    Error(error) -> Error(errors.FileReadError(stamp_file, error))
    Ok(contents) ->
      contents
      |> string.split("\n")
      |> list.fold(Ok(dict.new()), fn(state, line) {
        use stamps <- result.try(state)
        case string.split(line, " ") {
          [key, sha, fetched] ->
            case int.parse(fetched) {
              Ok(fetched) ->
                Ok(dict.insert(stamps, key, Stamp(sha: sha, fetched: fetched)))
              Error(_) -> Ok(stamps)
            }
          _ -> Ok(stamps)
        }
      })
  }
}

// Whether `directory` is a git checkout, i.e. it has a `.git` entry (a
// directory for a normal clone, a file for a worktree or submodule). Merely
// existing is not enough: running `git fetch`/`git reset` in a non-git
// directory operates on the nearest enclosing repository instead.
fn is_git_checkout(directory: String) -> Bool {
  let git_dir = filepath.join(directory, ".git")
  case simplifile.is_directory(git_dir) {
    Ok(True) -> True
    _ ->
      case simplifile.is_file(git_dir) {
        Ok(True) -> True
        _ -> False
      }
  }
}
