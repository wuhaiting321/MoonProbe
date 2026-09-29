/// MoonProbe - assert tests
///
/// Unit tests for the assertion engine. The bodies are written inline so the
/// suite also runs on the `wasm-gc` backend, which has no file system.

/// Parse `.probe` source and return the expectations of its first case.
fn expect_of(source : String) -> @parser.Expect raise {
  match @parser.parse(source) {
    Ok(suite) => suite.cases[0].expect
    Err(msg) => fail("fixture should parse: \{msg}")
  }
}

test "check_status accepts a matching code" {
  match @assert.check_status(200, 200) {
    Ok(_) => ()
    Err(msg) => fail("expected a match, got \{msg}")
  }
}

test "check_status reports a mismatching code" {
  match @assert.check_status(200, 404) {
    Ok(_) => fail("expected a mismatch")
    Err(msg) => @test.assert_eq(msg, "status: expected 200, got 404")
  }
}

test "check_json_path compares a nested numeric field" {
  let body = "{\"code\":0,\"data\":{\"count\":3}}"
  match @assert.check_json_path(body, "data.count", "3") {
    Ok(_) => ()
    Err(msg) => fail("expected the field to match, got \{msg}")
  }
}

test "check_json_path compares a string field" {
  let body = "{\"name\":\"alice\"}"
  match @assert.check_json_path(body, "name", "alice") {
    Ok(_) => ()
    Err(msg) => fail("expected the field to match, got \{msg}")
  }
}

test "check_json_path reports a mismatching value" {
  let body = "{\"code\":7}"
  match @assert.check_json_path(body, "code", "0") {
    Ok(_) => fail("expected a mismatch")
    Err(msg) => @test.assert_eq(msg, "json: code: expected \"0\", got \"7\"")
  }
}

test "check_json_path reports a missing path" {
  let body = "{\"code\":0}"
  match @assert.check_json_path(body, "data.count", "3") {
    Ok(_) => fail("expected a missing path")
    Err(msg) =>
      @test.assert_eq(
        msg,
        "json: path \"data.count\" not found in the response body",
      )
  }
}

test "check_json_path rejects a body that is not json" {
  match @assert.check_json_path("not json", "code", "0") {
    Ok(_) => fail("expected an invalid body to be rejected")
    Err(_) => ()
  }
}

test "check_json_path rejects a non-scalar value" {
  let body = "{\"data\":{\"count\":3}}"
  match @assert.check_json_path(body, "data", "3") {
    Ok(_) => fail("expected an object to be rejected")
    Err(_) => ()
  }
}

test "check_expect passes when every expectation holds" {
  let source =
    #|name: "guarded"
    #|request:
    #|  url: "https://a.test"
    #|expect:
    #|  status: 200
    #|  json:
    #|    code: 0
    #|    data.count: 3
    #|
  let expect = expect_of(source)
  let failures = @assert.check_expect(
    expect,
    200,
    "{\"code\":0,\"data\":{\"count\":3}}",
  )
  @test.assert_eq(failures.length(), 0)
}

test "check_expect collects every failure" {
  let source =
    #|name: "guarded"
    #|request:
    #|  url: "https://a.test"
    #|expect:
    #|  status: 200
    #|  json:
    #|    code: 0
    #|    data.count: 3
    #|
  let expect = expect_of(source)
  let failures = @assert.check_expect(expect, 500, "{\"code\":7}")
  @test.assert_eq(failures.length(), 3)
}