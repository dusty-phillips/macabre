import errors
import filepath
import gleam/result
import shellout

pub fn clone(
  name: String,
  repo: String,
  git_ref: String,
  from_dir: String,
) -> Result(Nil, errors.Error) {
  let clone_dir = filepath.join(from_dir, name)
  use _ <- result.try(
    shellout.command("git", ["clone", repo, name], from_dir, [])
    |> result.map_error(errors.GitCloneError(name, _)),
  )
  shellout.command("git", ["checkout", git_ref], clone_dir, [])
  |> result.map_error(errors.GitCheckoutError(name, git_ref, _))
  |> result.replace(Nil)
}
