import errors
import filepath
import gleam/list
import gleam/result
import shellout
import simplifile

pub fn fetch(
  package_directory: String,
  name: String,
  version: String,
) -> Result(Nil, errors.Error) {
  let package_dir = filepath.join(package_directory, name)
  let tarball_name = name <> "-" <> version <> ".tar"
  let tarball_url = "https://repo.hex.pm/tarballs/" <> tarball_name
  use _ <- result.try(
    simplifile.create_directory_all(package_dir)
    |> result.map_error(errors.MkdirError(package_dir, _)),
  )
  use _ <- result.try(
    shellout.command(
      "curl",
      ["-L", "-o", tarball_name, tarball_url],
      package_dir,
      [],
    )
    |> result.map_error(errors.HexDownloadError(name, version, _)),
  )
  use _ <- result.try(
    shellout.command("tar", ["-xf", tarball_name], package_dir, [])
    |> result.map_error(errors.HexExtractError(name, version, _)),
  )
  use _ <- result.try(
    shellout.command("tar", ["-xzf", "contents.tar.gz"], package_dir, [])
    |> result.map_error(errors.HexExtractError(name, version, _)),
  )
  cleanup(package_dir, [
    tarball_name,
    "contents.tar.gz",
    "VERSION",
    "metadata.config",
    "CHECKSUM",
  ])
}

fn cleanup(
  package_dir: String,
  files: List(String),
) -> Result(Nil, errors.Error) {
  files
  |> list.fold(Ok(Nil), fn(state, filename) {
    use _ <- result.try(state)
    let path = filepath.join(package_dir, filename)
    use _ <- result.try(
      simplifile.delete(path)
      |> result.map_error(errors.DeleteError(path, _)),
    )
    Ok(Nil)
  })
}
