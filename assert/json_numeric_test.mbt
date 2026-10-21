/// MoonProbe - strict JSON numeric comparison tests
///
/// These cases pin down the type-aware mode of `json:` assertions:
///
///   - numbers compare by value, never by widening them to a common string, so
///     an expectation of `999` can never be satisfied by the number `7`;
///   - numbers and strings are different types, so `7` does not satisfy `"7"`
///     and `"7"` does not satisfy `7`;
///   - the decimal comparison is exact, so 19-digit integers that collapse to
///     the same `Double` still compare apart;
///   - zero, negative values, exponents and trailing fraction zeros all
///     canonicalise to the same value.
///
/// Every test drives the public entry point, so the quoting flag travels the
/// same path the parser uses.

///|
/// Require a mismatch and hand back its message.
fn expect_failure(
  body : String,
  path : String,
  expected : String,
  quoted : Bool,
) -> String raise {
  match @assert.check_json_path_typed(body, path, expected, quoted) {
    Ok(_) => fail("expected a mismatch for \{expected}")
    Err(msg) => msg
  }
}

///|
/// Require a match.
fn expect_match(
  body : String,
  path : String,
  expected : String,
  quoted : Bool,
) -> Unit raise {
  match @assert.check_json_path_typed(body, path, expected, quoted) {
    Ok(_) => ()
    Err(msg) => fail("expected a match, got \{msg}")
  }
}

// ---------------------------------------------------------------------------
// The reported regression: 7 must never satisfy 999
// ---------------------------------------------------------------------------

///|
test "number 7 does not satisfy an expectation of 999" {
  let msg = expect_failure("{\"code\":7}", "code", "999", false)
  @test.assert_eq(msg, "json: \"code\": expected Int 999, got Int 7")
}

///|
test "number 999 satisfies an expectation of 999" {
  expect_match("{\"code\":999}", "code", "999", false)
}

///|
test "number 7 satisfies an expectation of 7" {
  expect_match("{\"code\":7}", "code", "7", false)
}

// ---------------------------------------------------------------------------
// Zero and negative values
// ---------------------------------------------------------------------------

///|
test "zero satisfies an expectation of zero" {
  expect_match("{\"code\":0}", "code", "0", false)
}

///|
test "negative zero and zero are the same value" {
  expect_match("{\"code\":-0}", "code", "0", false)
  expect_match("{\"code\":0}", "code", "-0", false)
}

///|
test "negative one satisfies an expectation of negative one" {
  expect_match("{\"code\":-1}", "code", "-1", false)
}

///|
test "negative one does not satisfy an expectation of one" {
  let msg = expect_failure("{\"code\":-1}", "code", "1", false)
  @test.assert_eq(msg, "json: \"code\": expected Int 1, got Int -1")
}

///|
test "a negative expectation does not accept a positive value" {
  let msg = expect_failure("{\"code\":7}", "code", "-1", false)
  @test.assert_eq(msg, "json: \"code\": expected Int -1, got Int 7")
}

// ---------------------------------------------------------------------------
// Integers, floats and their boundary
// ---------------------------------------------------------------------------

///|
test "a float expectation requires a fractional value" {
  let msg = expect_failure("{\"ratio\":7}", "ratio", "7.5", false)
  @test.assert_eq(msg, "json: \"ratio\": expected Number 7.5, got Int 7")
}

///|
test "a float literal with no fractional part is typed as an integer" {
  // `7.0` denotes the same value as `7`, so the strict mode types it as an Int
  // and compares it by value. Only the written form differs.
  expect_match("{\"ratio\":7}", "ratio", "7.0", false)
  expect_match("{\"ratio\":7.0}", "ratio", "7", false)
}

///|
test "an integer expectation rejects a fractional value" {
  let msg = expect_failure("{\"ratio\":1.5}", "ratio", "2", false)
  @test.assert_eq(msg, "json: \"ratio\": expected Int 2, got Number 1.5")
}

///|
test "equal floats compare by value" {
  expect_match("{\"ratio\":1.5}", "ratio", "1.5", false)
}

///|
test "trailing fraction zeros do not change a float" {
  expect_match("{\"ratio\":1.5}", "ratio", "1.50", false)
}

///|
test "a different float is reported with both values" {
  let msg = expect_failure("{\"ratio\":1.5}", "ratio", "2.5", false)
  @test.assert_eq(msg, "json: \"ratio\": expected Number 2.5, got Number 1.5")
}

///|
test "an exponent literal equals its expanded value" {
  expect_match("{\"n\":1000}", "n", "1e3", false)
}

///|
test "an expanded literal equals its exponent form" {
  expect_match("{\"n\":1e3}", "n", "1000", false)
}

///|
test "a fractional exponent is compared exactly" {
  expect_match("{\"n\":0.001}", "n", "1e-3", false)
}

///|
test "an integral exponent is an integer, not a float" {
  expect_match("{\"n\":1e3}", "n", "1000.0", false)
  expect_match("{\"n\":1000.0}", "n", "1e3", false)
}

// ---------------------------------------------------------------------------
// Exactness beyond the double range
// ---------------------------------------------------------------------------

///|
test "a 53-bit integer keeps every digit" {
  // Both literals round to the same Double; the decimal comparison must not.
  expect_match("{\"id\":9007199254740993}", "id", "9007199254740993", false)
  let msg = expect_failure(
    "{\"id\":9007199254740993}", "id", "9007199254740992", false,
  )
  @test.assert_eq(
    msg, "json: \"id\": expected Int 9007199254740992, got Int 9007199254740993",
  )
}

///|
test "a 19-digit integer keeps every digit" {
  expect_match(
    "{\"id\":1234567890123456789}", "id", "1234567890123456789", false,
  )
  let msg = expect_failure(
    "{\"id\":1234567890123456789}", "id", "1234567890123456788", false,
  )
  @test.assert_eq(
    msg, "json: \"id\": expected Int 1234567890123456788, got Int 1234567890123456789",
  )
}

// ---------------------------------------------------------------------------
// Numbers versus strings and other scalar types
// ---------------------------------------------------------------------------

///|
test "a quoted expectation asks for a string, not a number" {
  let msg = expect_failure("{\"code\":7}", "code", "7", true)
  @test.assert_eq(msg, "json: \"code\": expected String \"7\", got Int 7")
}

///|
test "a quoted numeric string satisfies a quoted expectation" {
  expect_match("{\"code\":\"7\"}", "code", "7", true)
}

///|
test "a numeric expectation rejects a numeric string" {
  let msg = expect_failure("{\"code\":\"7\"}", "code", "7", false)
  @test.assert_eq(msg, "json: \"code\": expected Int 7, got String \"7\"")
}

///|
test "a numeric expectation rejects a numeric string of another value" {
  let msg = expect_failure("{\"code\":\"7\"}", "code", "999", false)
  @test.assert_eq(msg, "json: \"code\": expected Int 999, got String \"7\"")
}

///|
test "a bool does not satisfy a numeric expectation" {
  let msg = expect_failure("{\"flag\":true}", "flag", "1", false)
  @test.assert_eq(msg, "json: \"flag\": expected Int 1, got Bool true")
}

///|
test "a number does not satisfy a bool expectation" {
  let msg = expect_failure("{\"flag\":1}", "flag", "true", false)
  @test.assert_eq(msg, "json: \"flag\": expected Bool true, got Int 1")
}

///|
test "a bool satisfies a bool expectation" {
  expect_match("{\"flag\":false}", "flag", "false", false)
}

///|
test "null satisfies a null expectation" {
  expect_match("{\"extra\":null}", "extra", "null", false)
}

///|
test "a quoted null asks for the string, not for null" {
  let msg = expect_failure("{\"extra\":null}", "extra", "null", true)
  @test.assert_eq(
    msg, "json: \"extra\": expected String \"null\", got Null null",
  )
}

///|
test "a number does not satisfy a null expectation" {
  let msg = expect_failure("{\"extra\":0}", "extra", "null", false)
  @test.assert_eq(msg, "json: \"extra\": expected Null null, got Int 0")
}

// ---------------------------------------------------------------------------
// The quoting flag travels through the parser
// ---------------------------------------------------------------------------

///|
test "the parser keeps a quoted json expectation quoted" {
  let source =
    #|name: "quoted number"
    #|request:
    #|  url: "https://a.test"
    #|expect:
    #|  json:
    #|    code: "7"
    #|
  let expect = expect_of(source)
  let passing = @assert.check_expect(expect, 200, "{\"code\":\"7\"}", 0UL)
  @test.assert_eq(passing.length(), 0)
  let failing = @assert.check_expect(expect, 200, "{\"code\":7}", 0UL)
  @test.assert_eq(failing.length(), 1)
  @test.assert_eq(
    failing[0],
    "json: \"code\": expected String \"7\", got Int 7",
  )
}

///|
test "the parser keeps an unquoted json expectation numeric" {
  let source =
    #|name: "bare number"
    #|request:
    #|  url: "https://a.test"
    #|expect:
    #|  json:
    #|    code: 999
    #|
  let expect = expect_of(source)
  let failing = @assert.check_expect(expect, 200, "{\"code\":7}", 0UL)
  @test.assert_eq(failing.length(), 1)
  @test.assert_eq(failing[0], "json: \"code\": expected Int 999, got Int 7")
}
