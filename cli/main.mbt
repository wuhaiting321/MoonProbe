/// MoonProbe - cli
///
/// The command-line entry point: locate the suite, read it, parse it, execute
/// every case through the runner and hand the results to the reporter.

/// Print the usage message.
fn print_usage() -> Unit {
  println("MoonProbe - a declarative API test runner")
  println("")
  println("Usage: moonprobe <path/to/suite.probe>")
  println("")
  println("Example:")
  println("  moon run cli --target js -- examples/httpbin.probe")
}

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

/// Run every case of `suite`, collecting the outcome of each one.
///
/// Returns `Err` as soon as a request cannot be performed at all, because the
/// remaining cases would fail the same way.
fn run_suite(suite : @parser.Suite) -> Result[Array[@runner.TestResult], String] {
  let results : Array[@runner.TestResult] = []
  for test_case in suite.cases {
    match @runner.run_test(test_case) {
      Ok(result) => results.push(result)
      Err(msg) => return Err("\{test_case.name}: \{msg}")
    }
  }
  return Ok(results)
}

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
  let results = match run_suite(suite) {
    Ok(results) => results
    Err(msg) => {
      println("error: \{msg}")
      return
    }
  }
  @reporter.print_report(results, @env.now() - started)
}