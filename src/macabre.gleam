import glance
import gleam/io

const code = "
  pub type Cardinal {
    North
    East
    South
    West
  }
"

pub fn main() {
  let assert Ok(parsed) = glance.module(code)
  io.debug(parsed.custom_types)
}
