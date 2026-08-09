import errors
import filepath
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
  case simplifile.is_directory(clone_dir) {
    Ok(True) -> {
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
    _ -> {
      use _ <- result.try(
        shellout.command("git", ["clone", repo, name], from_dir, [])
        |> result.map_error(errors.GitCloneError(name, _)),
      )
      shellout.command("git", ["checkout", git_ref], clone_dir, [])
      |> result.map_error(errors.GitCheckoutError(name, git_ref, _))
      |> result.replace(Nil)
    }
  }
}
