/// MoonProbe - runner
///
/// The end-to-end entry point. `run_suite` is what the CLI and the reporter are
/// built on: it walks the cases of a suite in declaration order, executes each
/// one, runs its expectation block and threads a single variable context through
/// the whole run so that a later case can use what an earlier one extracted.
///
/// Around every case the runner also performs the hooks the suite declared —
/// setup before, cleanup after — and each hook is itself a case, so a setup step
/// can sign in, assert that the sign-in worked, and leave a token behind for the
/// case it was preparing.

///|
/// The outcome of executing a single `.probe` case.
pub struct TestResult {
  /// The case name as declared in the `.probe` source.
  name : String
  /// The response the server returned, or `None` when a `before_each` step
  /// failed and the case body was therefore never sent.
  response : Response?
  /// Failure messages collected by the assertion engine, plus one per failing
  /// hook step. An empty array means the case passed.
  failures : Array[String]
  /// Wall-clock duration of the transport call that produced the response, in
  /// milliseconds — the number a `duration_ms` expectation is compared against and
  /// the one the JUnit report shows as the case time. It is 0 when the body was
  /// skipped, because then no request of this case was ever sent.
  elapsed_ms : UInt64
}

///|
/// Whether every assertion of the case held.
pub fn TestResult::passed(self : TestResult) -> Bool {
  return self.failures.length() == 0
}

///|
/// Append every element of `source` to `target`.
fn append_all(target : Array[String], source : Array[String]) -> Unit {
  for item in source {
    target.push(item)
  }
}

///|
/// Run one hook step and report what went wrong, each message prefixed with the
/// step's role and name so that a failure in a setup step is never mistaken for a
/// failure of the case itself.
///
/// A hook never aborts the run: a transport that cannot be reached is one more
/// line of explanation, which keeps the remaining cases — and the report — alive.
/// The step's `set:` extractions do reach the shared context, which is the whole
/// point of a setup step.
fn run_hook_step(
  transport : Transport,
  step : @parser.Case,
  config : @parser.Config,
  context : Map[String, String],
  timeout_ms : Int,
  role : String,
) -> Array[String] {
  let label = "\{role} \"\{step.name}\""
  let response = match
    run_request_with(transport, step.request, config, context, timeout_ms~) {
    Ok(r) => r
    Err(msg) => return ["\{label}: \{msg}"]
  }
  let failures : Array[String] = []
  for
    failure in @assert.check_expect(
      step.expect,
      response.status,
      response.body,
      response.elapsed_ms(),
    ) {
    failures.push(label + ": " + failure)
  }
  for spec in step.expect.sets {
    match extract_value(spec, response.headers, response.body) {
      Ok(value) => context[spec.name] = value
      Err(msg) => failures.push("\{label}: set \{spec.name}: \{msg}")
    }
  }
  return failures
}

///|
/// Execute one `.probe` case end to end: hooks, request, assertions, then the
/// `set:` extractions.
///
/// `config` is the suite's `config:` block, merged into the request before it is
/// sent: the base URL, the global headers, the global timeout and the retry budget
/// all take effect here, which is why this is a parameter rather than something
/// the case carries.
///
/// `context` is read to expand `{{name}}` references in the request and written
/// to with every variable the case extracts, so that the caller can pass the same
/// map to the next case.
///
/// `Err` is reserved for a request that could not be performed at all. A request
/// that completes with an unexpected status is still an `Ok` result carrying the
/// assertion failures, because the response itself is worth reporting. A failed
/// extraction is reported as one more failure instead of aborting the run.
pub fn run_test(
  test_case : @parser.Case,
  config : @parser.Config,
  context : Map[String, String],
  timeout_ms? : Int = DEFAULT_TIMEOUT_MS,
) -> Result[TestResult, String] {
  return run_case(send, test_case, config, context, [], [], timeout_ms)
}

///|
/// Execute one case together with the hooks that surround it.
///
/// The order is the nesting order, outermost first on the way in and outermost
/// last on the way out:
///
/// ```text
/// suite before_each -> case before_each -> the case -> case after_each -> suite after_each
/// ```
///
/// A failing `before_each` step blocks the case body: sending a request that
/// expects a fixture which was never prepared produces a cascade of failures that
/// bury the one real cause. Cleanup still runs, on every path, because a step that
/// tears a fixture down matters most exactly when the case went wrong.
fn run_case(
  transport : Transport,
  test_case : @parser.Case,
  config : @parser.Config,
  context : Map[String, String],
  suite_before : Array[@parser.Case],
  suite_after : Array[@parser.Case],
  timeout_ms : Int,
) -> Result[TestResult, String] {
  let failures : Array[String] = []
  let mut blocked = false
  for step in suite_before {
    let step_failures = run_hook_step(
      transport, step, config, context, timeout_ms, "before_each",
    )
    append_all(failures, step_failures)
    if step_failures.length() > 0 {
      blocked = true
    }
  }
  if !blocked {
    for step in test_case.before_each {
      let step_failures = run_hook_step(
        transport, step, config, context, timeout_ms, "before_each",
      )
      append_all(failures, step_failures)
      if step_failures.length() > 0 {
        blocked = true
        // A later setup step usually depends on an earlier one, so the first
        // failure ends the setup phase instead of piling on follow-up errors.
        break
      }
    }
  }
  let mut response : Response? = None
  if !blocked {
    let sent = match
      run_request_with(
        transport,
        test_case.request,
        config,
        context,
        timeout_ms~,
      ) {
      Ok(r) => r
      Err(msg) => return Err(msg)
    }
    for
      failure in @assert.check_expect(
        test_case.expect,
        sent.status,
        sent.body,
        sent.elapsed_ms(),
      ) {
      failures.push(failure)
    }
    // Extraction goes through the runner's own reader rather than the JSON one
    // alone, so a `set:` may bind what a response header or cookie carries just as
    // well as what its body does.
    for spec in test_case.expect.sets {
      match extract_value(spec, sent.headers, sent.body) {
        Ok(value) => context[spec.name] = value
        Err(msg) => failures.push("set \{spec.name}: \{msg}")
      }
    }
    response = Some(sent)
  }
  for step in test_case.after_each {
    append_all(
      failures,
      run_hook_step(transport, step, config, context, timeout_ms, "after_each"),
    )
  }
  for step in suite_after {
    append_all(
      failures,
      run_hook_step(transport, step, config, context, timeout_ms, "after_each"),
    )
  }
  let elapsed_ms = match response {
    Some(r) => r.elapsed_ms()
    None => 0UL
  }
  return Ok({ name: test_case.name, response, failures, elapsed_ms, })
}

///|
/// Execute every case of a suite, in declaration order.
///
/// One variable context is created for the run and shared by all cases, which is
/// what turns a login case into an authenticated follow-up case. The suite's own
/// `config:` block is applied to every case of the run, and its `before_each` /
/// `after_each` blocks surround every case.
pub fn run_suite(
  suite : @parser.Suite,
  timeout_ms? : Int = DEFAULT_TIMEOUT_MS,
) -> Result[Array[TestResult], String] {
  return run_suite_with(send, suite, timeout_ms~)
}

///|
/// Execute every case of a suite through a caller-supplied transport.
///
/// This is the whole pipeline bound to one function: the parsed suite comes in,
/// each case is resolved against the suite config, its placeholders are expanded,
/// the request is sent and retried as needed, the assertions run over the reply
/// and one result per case comes out. A test supplies a scripted transport and
/// therefore exercises the entire path — parsing, config merge, variable
/// injection, transport, assertion — without a network.
pub fn run_suite_with(
  transport : Transport,
  suite : @parser.Suite,
  timeout_ms? : Int = DEFAULT_TIMEOUT_MS,
) -> Result[Array[TestResult], String] {
  let context = new_context()
  let results : Array[TestResult] = []
  for test_case in suite.cases {
    match
      run_case(
        transport,
        test_case,
        suite.config,
        context,
        suite.before_each,
        suite.after_each,
        timeout_ms,
      ) {
      Ok(result) => results.push(result)
      Err(msg) => return Err("\{test_case.name}: \{msg}")
    }
  }
  return Ok(results)
}
