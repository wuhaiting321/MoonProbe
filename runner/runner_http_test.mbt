/// MoonProbe - runner transport tests
///
/// These exercise a real network round trip, so they only run on the `js`
/// target, where the host provides `curl` through Node.js `child_process`.

#cfg(target="js")
test "run_request performs a real http round trip" {
  let source =
    #|name: "real request"
    #|request:
    #|  url: "https://example.com"
    #|expect:
    #|  status: 200
    #|
  let request = match @parser.parse(source) {
    Ok(suite) => suite.cases[0].request
    Err(msg) => fail("fixture should parse: \{msg}")
  }
  let response = match @runner.run_request(request) {
    Ok(r) => r
    Err(msg) => fail("request should succeed: \{msg}")
  }
  @test.assert_eq(response.status, 200)
  @test.assert_eq(response.body.length() > 0, true)
}

#cfg(target="js")
test "run_request surfaces transport failures as Err" {
  let source =
    #|name: "dead host"
    #|request:
    #|  url: "https://definitely-not-a-real-host.invalid/"
    #|expect:
    #|  status: 200
    #|
  let request = match @parser.parse(source) {
    Ok(suite) => suite.cases[0].request
    Err(msg) => fail("fixture should parse: \{msg}")
  }
  match @runner.run_request(request, timeout_ms=5000) {
    Err(_) => ()
    Ok(response) => fail("expected a transport error, got \{response.status}")
  }
}

/// Parse `.probe` source into the case it declares.
#cfg(target="js")
fn case_of(source : String) -> @parser.Case raise {
  match @parser.parse(source) {
    Ok(suite) => suite.cases[0]
    Err(msg) => fail("fixture should parse: \{msg}")
  }
}

#cfg(target="js")
test "run_test reports a passing case end to end" {
  let source =
    #|name: "end to end"
    #|request:
    #|  url: "https://example.com"
    #|expect:
    #|  status: 200
    #|
  let result = match @runner.run_test(case_of(source)) {
    Ok(r) => r
    Err(msg) => fail("case should run: \{msg}")
  }
  @test.assert_eq(result.name, "end to end")
  @test.assert_eq(result.response.status, 200)
  @test.assert_eq(result.passed(), true)
}

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
  let result = match @runner.run_test(case_of(source)) {
    Ok(r) => r
    Err(msg) => fail("case should run: \{msg}")
  }
  @test.assert_eq(result.passed(), false)
  @test.assert_eq(result.failures.length(), 2)
}