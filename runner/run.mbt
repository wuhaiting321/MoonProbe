/// MoonProbe - runner
///
/// The end-to-end entry point. `run_test` is what the CLI and the reporter are
/// built on: it turns one parsed `.probe` case into a request, executes it, runs
/// the expectation block and reports the outcome.

/// The outcome of executing a single `.probe` case.
pub struct TestResult {
  /// The case name as declared in the `.probe` source.
  name : String
  /// The response the server returned.
  response : Response
  /// Failure messages collected by the assertion engine. An empty array means
  /// the case passed.
  failures : Array[String]
}

/// Whether every assertion of the case held.
pub fn TestResult::passed(self : TestResult) -> Bool {
  return self.failures.length() == 0
}

/// Execute one `.probe` case end to end: request, then assertions.
///
/// `Err` is reserved for a request that could not be performed at all. A request
/// that completes with an unexpected status is still an `Ok` result carrying the
/// assertion failures, because the response itself is worth reporting.
pub fn run_test(
  test_case : @parser.Case,
  timeout_ms? : Int = DEFAULT_TIMEOUT_MS
) -> Result[TestResult, String] {
  let response = match run_request(test_case.request, timeout_ms~) {
    Ok(r) => r
    Err(msg) => return Err(msg)
  }
  let failures = @assert.check_expect(
    test_case.expect,
    response.status,
    response.body,
  )
  return Ok({
    name: test_case.name,
    response: response,
    failures: failures,
  })
}