/// MoonProbe - runner
///
/// The end-to-end entry point. `run_suite` is what the CLI and the reporter are
/// built on: it walks the cases of a suite in declaration order, executes each
/// one, runs its expectation block and threads a single variable context through
/// the whole run so that a later case can use what an earlier one extracted.

///|
/// The outcome of executing a single `.probe` case.
pub struct TestResult {
  /// The case name as declared in the `.probe` source.
  name : String
  /// The response the server returned.
  response : Response
  /// Failure messages collected by the assertion engine. An empty array means
  /// the case passed.
  failures : Array[String]
  /// Wall-clock duration of the request itself, in milliseconds. It is measured
  /// around the transport call only, so it is what a `duration_ms` expectation
  /// is compared against and what the JUnit report shows as the case time.
  elapsed_ms : UInt64
}

///|
/// Whether every assertion of the case held.
pub fn TestResult::passed(self : TestResult) -> Bool {
  return self.failures.length() == 0
}

///|
/// Execute one `.probe` case end to end: request, then assertions, then the
/// `set:` extractions.
///
/// `context` is read to expand `{{name}}` references in the request and written
/// to with every variable the case extracts, so that the caller can pass the
/// same map to the next case.
///
/// `Err` is reserved for a request that could not be performed at all. A request
/// that completes with an unexpected status is still an `Ok` result carrying the
/// assertion failures, because the response itself is worth reporting. A failed
/// extraction is reported as one more failure instead of aborting the run.
pub fn run_test(
  test_case : @parser.Case,
  context : Map[String, String],
  timeout_ms? : Int = DEFAULT_TIMEOUT_MS,
) -> Result[TestResult, String] {
  let started = @env.now()
  let response = match run_request(test_case.request, context, timeout_ms~) {
    Ok(r) => r
    Err(msg) => return Err(msg)
  }
  // Measured around the transport call only: a `duration_ms` expectation is a
  // budget on the server, not on the assertion engine.
  let elapsed_ms = @env.now() - started
  let failures = @assert.check_expect(
    test_case.expect,
    response.status,
    response.body,
    elapsed_ms,
  )
  for spec in test_case.expect.sets {
    match @assert.read_json_path(response.body, spec.path) {
      Ok(value) => context[spec.name] = value
      Err(msg) => failures.push("set \{spec.name}: \{msg}")
    }
  }
  return Ok({ name: test_case.name, response, failures, elapsed_ms, })
}

///|
/// Execute every case of a suite, in declaration order.
///
/// One variable context is created for the run and shared by all cases, which is
/// what turns a login case into an authenticated follow-up case.
pub fn run_suite(
  suite : @parser.Suite,
  timeout_ms? : Int = DEFAULT_TIMEOUT_MS,
) -> Result[Array[TestResult], String] {
  let context = new_context()
  let results : Array[TestResult] = []
  for test_case in suite.cases {
    match run_test(test_case, context, timeout_ms~) {
      Ok(result) => results.push(result)
      Err(msg) => return Err("\{test_case.name}: \{msg}")
    }
  }
  return Ok(results)
}
