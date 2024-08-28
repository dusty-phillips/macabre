import errors
import gleam/result
import shellout

pub fn clone(
  name: String,
  repo: String,
  from_dir: String,
) -> Result(Nil, errors.Error) {
  shellout.command("git", ["clone", repo, name], from_dir, [])
  |> result.map_error(errors.GitCloneError(name, _))
  |> result.replace(Nil)
}
