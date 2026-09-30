///|
/// MoonProbe - runner transport tests
///
/// These exercise a real network round trip, so they only run on the `js`
/// target, where the host provides `curl` through Node.js `child_process`.

///|
/// The first case and its suite config, ready to be handed to the runner.
#cfg(target="js")
fn case_of(source : String) -> (@parser.Case, @parser.Config) raise {
  match @parser.parse(source) {
    Ok(suite) => (suite.cases[0], suite.config)
    Err(msg) => fail("fixture should parse: \{msg}")
  }
}

///|
#cfg(target="js")
test "run_request performs a real http round trip" {
  let source =
    #|name: "real request"
    #|request:
    #|  url: "https://example.com"
    #|expect:
    #|  status: 200
    #|
  let (test_case, config) = case_of(source)
  let response = match
    @runner.run_request(test_case.request, config, @runner.new_context()) {
    Ok(r) => r
    Err(msg) => fail("request should succeed: \{msg}")
  }
  @test.assert_eq(response.status, 200)
  @test.assert_eq(response.body.length() > 0, true)
  // The transport asks for the headers too, so a response always carries them.
  @test.assert_eq(response.headers.length() > 0, true)
}

///|
#cfg(target="js")
test "run_request surfaces transport failures as Err" {
  let source =
    #|name: "dead host"
    #|request:
    #|  url: "https://definitely-not-a-real-host.invalid/"
    #|expect:
    #|  status: 200
    #|
  let (test_case, config) = case_of(source)
  match
    @runner.run_request(
      test_case.request,
      config,
      @runner.new_context(),
      timeout_ms=5000,
    ) {
    Err(_) => ()
    Ok(response) => fail("expected a transport error, got \{response.status}")
  }
}

///|
#cfg(target="js")
test "run_test reports a passing case end to end" {
  let source =
    #|name: "end to end"
    #|request:
    #|  url: "https://example.com"
    #|expect:
    #|  status: 200
    #|
  let (test_case, config) = case_of(source)
  let result = match
    @runner.run_test(test_case, config, @runner.new_context()) {
    Ok(r) => r
    Err(msg) => fail("case should run: \{msg}")
  }
  @test.assert_eq(result.name, "end to end")
  @test.assert_eq(result.response.status, 200)
  @test.assert_eq(result.passed(), true)
}

///|
#cfg(target="js")
test "run_test resolves a relative url against the suite base_url" {
  let source =
    #|config:
    #|  base_url: "https://example.com"
    #|name: "relative url"
    #|request:
    #|  url: "/"
    #|expect:
    #|  status: 200
    #|
  let (test_case, config) = case_of(source)
  let result = match
    @runner.run_test(test_case, config, @runner.new_context()) {
    Ok(r) => r
    Err(msg) => fail("case should run: \{msg}")
  }
  @test.assert_eq(result.passed(), true)
}

///|
#cfg(target="js")
test "run_test binds a value read from a response header" {
  // The one assertion that proves the transport really asked for the headers:
  // `example.com` always describes its body, so the directive must find it.
  let source =
    #|name: "header extraction"
    #|request:
    #|  url: "https://example.com"
    #|expect:
    #|  status: 200
    #|  set: kind = header.Content-Type
    #|
  let (test_case, config) = case_of(source)
  let context = @runner.new_context()
  let result = match @runner.run_test(test_case, config, context) {
    Ok(r) => r
    Err(msg) => fail("case should run: \{msg}")
  }
  @test.assert_eq(result.passed(), true)
  match context.get("kind") {
    Some(value) => @test.assert_eq(value.contains("text/html"), true)
    None => fail("Content-Type should have been bound to `kind`")
  }
}

///|
#cfg(target="js")
test "run_test carries the assertion failures of a mismatching case" {
  let source =
    #|name: "wrong expectation"
    #|request:
    #|  url: "https://example.com"
    #|expect:
    #|  status: 404
    #|  json:
    #|    missing: "nope"
    #|
  let (test_case, config) = case_of(source)
  let result = match
    @runner.run_test(test_case, config, @runner.new_context()) {
    Ok(r) => r
    Err(msg) => fail("case should run: \{msg}")
  }
  @test.assert_eq(result.passed(), false)
  @test.assert_eq(result.failures.length(), 2)
}

///|
#cfg(target="js")
test "run_suite executes every case and shares one context" {
  let source =
    #|name: "suite first"
    #|request:
    #|  url: "https://example.com"
    #|expect:
    #|  status: 200
    #|name: "suite second"
    #|request:
    #|  url: "https://example.com"
    #|expect:
    #|  status: 200
    #|
  let suite = match @parser.parse(source) {
    Ok(s) => s
    Err(msg) => fail("fixture should parse: \{msg}")
  }
  let results = match @runner.run_suite(suite) {
    Ok(r) => r
    Err(msg) => fail("suite should run: \{msg}")
  }
  @test.assert_eq(results.length(), 2)
  @test.assert_eq(results[0].name, "suite first")
  @test.assert_eq(results[1].name, "suite second")
  @test.assert_eq(results[0].passed(), true)
  @test.assert_eq(results[1].passed(), true)
}

///|
#cfg(target="js")
test "run_test records a failed extraction as a failure" {
  let source =
    #|name: "bad extraction"
    #|request:
    #|  url: "https://example.com"
    #|expect:
    #|  status: 200
    #|  set: token = data.token
    #|
  // example.com answers with HTML, so the path cannot be read: the case must
  // fail with an extraction message rather than abort the whole run.
  let (test_case, config) = case_of(source)
  let context = @runner.new_context()
  let result = match @runner.run_test(test_case, config, context) {
    Ok(r) => r
    Err(msg) => fail("case should run: \{msg}")
  }
  @test.assert_eq(result.passed(), false)
  @test.assert_eq(result.failures.length(), 1)
  match context.get("token") {
    None => ()
    Some(v) => fail("token should not be bound, got \{v}")
  }
}

///|
#cfg(target="js")
test "run_test feeds the measured duration and the raw body to the assertions" {
  // `example.com` answers with HTML, so this case exercises the two checks that
  // do not need a JSON body at all: a case-insensitive `contains_ci` over the
  // raw text, and a duration budget compared against the time the transport
  // call itself took.
  let source =
    #|name: "duration budget"
    #|request:
    #|  url: "https://example.com"
    #|expect:
    #|  status: 200
    #|  contains_ci: "example domain"
    #|  duration_ms >= 0
    #|
  let (test_case, config) = case_of(source)
  let result = match
    @runner.run_test(test_case, config, @runner.new_context()) {
    Ok(r) => r
    Err(msg) => fail("case should run: \{msg}")
  }
  @test.assert_eq(result.passed(), true)

  // A budget of zero under a strict `<` can never hold, whatever the round trip
  // costs, which pins the failure on the wiring rather than on the network.
  let impossible =
    #|name: "impossible budget"
    #|request:
    #|  url: "https://example.com"
    #|expect:
    #|  status: 200
    #|  duration_ms < 0
    #|
  let (case_fail, config_fail) = case_of(impossible)
  let failed = match
    @runner.run_test(case_fail, config_fail, @runner.new_context()) {
    Ok(r) => r
    Err(msg) => fail("case should run: \{msg}")
  }
  @test.assert_eq(failed.passed(), false)
  @test.assert_eq(failed.failures.length(), 1)
  @test.assert_eq(
    failed.failures[0].contains("duration: expected < 0 ms, took "),
    true,
  )
}
