//
// MoonProbe - cli package
//
// The `cli` package exposes the native command-line entrypoint of MoonProbe.
//
// Responsibilities (landed in the dedicated cli feature commits):
//
//   - parse CLI arguments (input `.probe` path, report format, timeout, ...)
//   - read the `.probe` text file from disk
//   - orchestrate parser -> runner -> assert -> reporter
//   - set the process exit code based on the overall test result
//
// This module is intentionally empty in the scaffold commit. The executable
// entrypoint is implemented in the dedicated cli feature commit.

/// Placeholder entry point so the executable package compiles during the
/// skeleton phase. Replaced by real argument parsing in the cli feature commit.
fn main {
  println("MoonProbe: skeleton ready")
}