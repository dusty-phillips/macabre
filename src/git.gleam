import errors
import filepath
import filesystem
import gleam/result
import shellout
import simplifile

pub fn clone(
  name: String,
  repo: String,
  git_ref: String,
  from_dir: String,
) -> Result(Nil, errors.Error) {
  let clone_dir = filepath.join(from_dir, name)
  case is_git_checkout(clone_dir) {
    True -> {
      // An existing clone: just update it to the requested ref rather than
      // re-cloning the whole repository.
      use _ <- result.try(
        shellout.command("git", ["fetch", "origin", git_ref], clone_dir, [])
        |> result.map_error(errors.GitCloneError(name, _)),
      )
      shellout.command("git", ["reset", "--hard", "FETCH_HEAD"], clone_dir, [])
      |> result.map_error(errors.GitCloneError(name, _))
      |> result.replace(Nil)
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
    }
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
