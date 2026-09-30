/// MoonProbe - cli
///
/// The command-line entry point: locate the suite, read it, parse it, execute
/// every case through the runner and hand the results to the reporter. When
/// `--junit <path>` is given, the run is also written out as JUnit XML.

///|
/// Print the usage message.
fn print_usage() -> Unit {
  println("MoonProbe - a declarative API test runner")
  println("")
  println(
    "Usage: moonprobe <path/to/suite.probe> [--junit <path/to/report.xml>]",
  )
  println("")
  println("Example:")
  println("  moon run cli --target js -- examples/httpbin.probe")
  println(
    "  moon run cli --target js -- examples/httpbin.probe --junit junit.xml",
  )
}

///|
/// Pick the `.probe` path out of the command line.
///
/// The leading arguments differ per backend — on the `js` target the Node.js
/// executable and the generated script come first — so the suite is selected by
/// file extension instead of by position. The last match wins, which keeps
/// `--examples/demo.probe`-style overrides working.
fn suite_path(args : Array[String]) -> String? {
  let mut i = args.length()
  while i > 0 {
    i = i - 1
    if args[i].has_suffix(".probe") {
      return Some(args[i])
    }
  }
  return None
}

///|
/// The path given after `--junit`, if any.
fn junit_path(args : Array[String]) -> String? {
  let mut i = 0
  while i + 1 < args.length() {
    if args[i] == "--junit" {
      return Some(args[i + 1])
    }
    i = i + 1
  }
  return None
}

///|
fn main {
  let args = @env.args()
  let path = match suite_path(args) {
    Some(path) => path
    None => {
      print_usage()
      return
    }
  }
  let source = match read_source(path) {
    Ok(source) => source
    Err(msg) => {
      println("error: \{msg}")
      return
    }
  }
  let suite = match @parser.parse(source) {
    Ok(suite) => suite
    Err(msg) => {
      println("error: \{path}: \{msg}")
      return
    }
  }
  let started = @env.now()
  let results = match @runner.run_suite(suite) {
    Ok(results) => results
    Err(msg) => {
      println("error: \{msg}")
      return
    }
  }
  let elapsed = @env.now() - started
  @reporter.print_report(results, elapsed)
  match junit_path(args) {
    Some(out) =>
      match write_report(out, @reporter.to_junit_xml(results, elapsed)) {
        Ok(_) => println("JUnit XML written to \{out}")
        Err(msg) => println("error: \{msg}")
      }
    None => ()
  }
}
