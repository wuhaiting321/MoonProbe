/// MoonProbe - assert tests
///
/// Unit tests for the assertion engine. The bodies are written inline so the
/// suite also runs on the `wasm-gc` backend, which has no file system.

///|
/// Parse `.probe` source and return the expectations of its first case.
fn expect_of(source : String) -> @parser.Expect raise {
  match @parser.parse(source) {
    Ok(suite) => suite.cases[0].expect
    Err(msg) => fail("fixture should parse: \{msg}")
  }
}

///|
/// The JSON type a `.probe` name denotes, so that the type tests read as
/// `type_of("Int")` rather than as a constructor path.
fn type_of(name : String) -> @parser.JsonType raise {
  match @parser.json_type_of(name) {
    Some(t) => t
    None => fail("the type name should be known")
  }
}

///|
test "check_status accepts a matching code" {
  match @assert.check_status(200, 200) {
    Ok(_) => ()
    Err(msg) => fail("expected a match, got \{msg}")
  }
}

///|
test "check_status reports a mismatching code" {
  match @assert.check_status(200, 404) {
    Ok(_) => fail("expected a mismatch")
    Err(msg) => @test.assert_eq(msg, "status: expected 200, got 404")
  }
}

///|
test "check_json_path compares a nested numeric field" {
  let body = "{\"code\":0,\"data\":{\"count\":3}}"
  match @assert.check_json_path(body, "data.count", "3") {
    Ok(_) => ()
    Err(msg) => fail("expected the field to match, got \{msg}")
  }
}

///|
test "check_json_path compares a string field" {
  let body = "{\"name\":\"alice\"}"
  match @assert.check_json_path(body, "name", "alice") {
    Ok(_) => ()
    Err(msg) => fail("expected the field to match, got \{msg}")
  }
}

///|
test "check_json_path reports a mismatching value" {
  let body = "{\"code\":7}"
  match @assert.check_json_path(body, "code", "0") {
    Ok(_) => fail("expected a mismatch")
    Err(msg) => @test.assert_eq(msg, "json: code: expected \"0\", got \"7\"")
  }
}

///|
test "check_json_path reports a missing path" {
  let body = "{\"code\":0}"
  match @assert.check_json_path(body, "data.count", "3") {
    Ok(_) => fail("expected a missing path")
    Err(msg) =>
      @test.assert_eq(
        msg, "json: path \"data.count\" not found in the response body",
      )
  }
}

///|
test "check_json_path rejects a body that is not json" {
  match @assert.check_json_path("not json", "code", "0") {
    Ok(_) => fail("expected an invalid body to be rejected")
    Err(_) => ()
  }
}

///|
test "check_json_path rejects a non-scalar value" {
  let body = "{\"data\":{\"count\":3}}"
  match @assert.check_json_path(body, "data", "3") {
    Ok(_) => fail("expected an object to be rejected")
    Err(_) => ()
  }
}

///|
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
    expect, 200, "{\"code\":0,\"data\":{\"count\":3}}", 40UL,
  )
  @test.assert_eq(failures.length(), 0)
}

///|
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
  let failures = @assert.check_expect(expect, 500, "{\"code\":7}", 12UL)
  @test.assert_eq(failures.length(), 3)
}

// ---------------------------------------------------------------------------
// contains
// ---------------------------------------------------------------------------

///|
test "check_contains finds a case-sensitive substring" {
  match @assert.check_contains("{\"msg\":\"ok\"}", "ok", false) {
    Ok(_) => ()
    Err(msg) => fail("expected the body to contain the text, got \{msg}")
  }
}

///|
test "check_contains reports a missing substring" {
  match @assert.check_contains("{\"msg\":\"nope\"}", "ok", false) {
    Ok(_) => fail("expected a mismatch")
    Err(msg) => @test.assert_eq(msg, "contains: body does not contain \"ok\"")
  }
}

///|
test "check_contains rejects a different case when case-sensitive" {
  match @assert.check_contains("OK", "ok", false) {
    Ok(_) => fail("expected case to matter")
    Err(_) => ()
  }
}

///|
test "check_contains folds case when asked" {
  match @assert.check_contains("{\"msg\":\"OK\"}", "ok", true) {
    Ok(_) => ()
    Err(msg) => fail("expected a folded match, got \{msg}")
  }
}

///|
test "check_contains explains that case was folded" {
  match @assert.check_contains("nothing here", "OK", true) {
    Ok(_) => fail("expected a mismatch")
    Err(msg) =>
      @test.assert_eq(
        msg, "contains: body does not contain \"OK\" (ignoring case)",
      )
  }
}

///|
test "check_contains finds non-ascii text" {
  match @assert.check_contains("{\"msg\":\"操作成功\"}", "成功", false) {
    Ok(_) => ()
    Err(msg) => fail("expected a match, got \{msg}")
  }
}

///|
test "check_contains treats an empty needle as present" {
  match @assert.check_contains("", "", false) {
    Ok(_) => ()
    Err(msg) => fail("expected a match, got \{msg}")
  }
}

///|
test "check_contains reports a missing needle in an empty body" {
  match @assert.check_contains("", "ok", false) {
    Ok(_) => fail("expected a mismatch")
    Err(_) => ()
  }
}

///|
test "check_contains tolerates a body shorter than the needle" {
  match @assert.check_contains("ab", "abcdef", true) {
    Ok(_) => fail("expected a mismatch")
    Err(_) => ()
  }
}

// ---------------------------------------------------------------------------
// length
// ---------------------------------------------------------------------------

///|
test "check_length accepts a matching element count" {
  match @assert.check_length("{\"items\":[1,2,3]}", "items", 3) {
    Ok(_) => ()
    Err(msg) => fail("expected the count to match, got \{msg}")
  }
}

///|
test "check_length reports a wrong element count" {
  match @assert.check_length("{\"items\":[1,2]}", "items", 3) {
    Ok(_) => fail("expected a mismatch")
    Err(msg) =>
      @test.assert_eq(msg, "length: \"items\": expected 3 elements, got 2")
  }
}

///|
test "check_length accepts an empty array" {
  match @assert.check_length("{\"items\":[]}", "items", 0) {
    Ok(_) => ()
    Err(msg) => fail("expected the count to match, got \{msg}")
  }
}

///|
test "check_length addresses the body root through an empty path" {
  match @assert.check_length("[\"a\",\"b\"]", "", 2) {
    Ok(_) => ()
    Err(msg) => fail("expected the root to be checked, got \{msg}")
  }
}

///|
test "check_length names the body root in a failure" {
  match @assert.check_length("[1,2,3]", "", 2) {
    Ok(_) => fail("expected a mismatch")
    Err(msg) => @test.assert_eq(msg, "length: body: expected 2 elements, got 3")
  }
}

///|
test "check_length rejects a value that is not an array" {
  match @assert.check_length("{\"items\":{\"a\":1}}", "items", 1) {
    Ok(_) => fail("expected a non-array to be rejected")
    Err(msg) =>
      @test.assert_eq(msg, "length: \"items\": expected an array, got Object")
  }
}

///|
test "check_length rejects a scalar where an array is required" {
  match @assert.check_length("{\"items\":7}", "items", 1) {
    Ok(_) => fail("expected a scalar to be rejected")
    Err(msg) =>
      @test.assert_eq(msg, "length: \"items\": expected an array, got Int")
  }
}

///|
test "check_length reports a missing path" {
  match @assert.check_length("{\"items\":[]}", "data.items", 0) {
    Ok(_) => fail("expected a missing path to be reported")
    Err(msg) =>
      @test.assert_eq(
        msg, "length: \"data.items\" not found in the response body",
      )
  }
}

///|
test "check_length rejects a body that is not json" {
  match @assert.check_length("not json", "", 1) {
    Ok(_) => fail("expected an invalid body to be rejected")
    Err(msg) => @test.assert_eq(msg.has_prefix("length: "), true)
  }
}

// ---------------------------------------------------------------------------
// type
// ---------------------------------------------------------------------------

///|
test "check_json_type accepts an integer" {
  match @assert.check_json_type("{\"code\":0}", "code", type_of("Int")) {
    Ok(_) => ()
    Err(msg) => fail("expected an integer, got \{msg}")
  }
}

///|
test "check_json_type accepts a negative integer" {
  match @assert.check_json_type("{\"code\":-3}", "code", type_of("Int")) {
    Ok(_) => ()
    Err(msg) => fail("expected an integer, got \{msg}")
  }
}

///|
test "check_json_type separates a float from an integer" {
  match @assert.check_json_type("{\"ratio\":1.5}", "ratio", type_of("Int")) {
    Ok(_) => fail("a float is not an integer")
    Err(msg) =>
      @test.assert_eq(msg, "type: \"ratio\": expected Int, got Number")
  }
}

///|
test "check_json_type accepts a float as a number" {
  match @assert.check_json_type("{\"ratio\":1.5}", "ratio", type_of("Number")) {
    Ok(_) => ()
    Err(msg) => fail("expected a number, got \{msg}")
  }
}

///|
test "check_json_type judges integrality on the value, not on the notation" {
  // The decoder keeps the source text of a number only for values it cannot
  // represent exactly, so `1e3` arrives as the integral value 1000 and counts
  // as an Int; `1.5e0` keeps a fractional part and does not.
  match @assert.check_json_type("{\"n\":1e3}", "n", type_of("Int")) {
    Ok(_) => ()
    Err(msg) => fail("`1e3` denotes the integral value 1000, got \{msg}")
  }
  match @assert.check_json_type("{\"n\":1.5e0}", "n", type_of("Int")) {
    Ok(_) => fail("`1.5e0` has a fractional part")
    Err(msg) => @test.assert_eq(msg, "type: \"n\": expected Int, got Number")
  }
}

///|
test "check_json_type accepts a string" {
  match
    @assert.check_json_type("{\"name\":\"alice\"}", "name", type_of("String")) {
    Ok(_) => ()
    Err(msg) => fail("expected a string, got \{msg}")
  }
}

///|
test "check_json_type accepts a bool" {
  match
    @assert.check_json_type("{\"active\":false}", "active", type_of("Bool")) {
    Ok(_) => ()
    Err(msg) => fail("expected a bool, got \{msg}")
  }
}

///|
test "check_json_type accepts null" {
  match @assert.check_json_type("{\"extra\":null}", "extra", type_of("Null")) {
    Ok(_) => ()
    Err(msg) => fail("expected null, got \{msg}")
  }
}

///|
test "check_json_type accepts an array" {
  match @assert.check_json_type("{\"tags\":[]}", "tags", type_of("Array")) {
    Ok(_) => ()
    Err(msg) => fail("expected an array, got \{msg}")
  }
}

///|
test "check_json_type accepts an object" {
  match @assert.check_json_type("{\"data\":{}}", "data", type_of("Object")) {
    Ok(_) => ()
    Err(msg) => fail("expected an object, got \{msg}")
  }
}

///|
test "check_json_type checks the body root" {
  match @assert.check_json_type("[1,2]", "", type_of("Array")) {
    Ok(_) => ()
    Err(msg) => fail("expected the root type to be checked, got \{msg}")
  }
}

///|
test "check_json_type reports a changed field type" {
  match @assert.check_json_type("{\"code\":\"7\"}", "code", type_of("Int")) {
    Ok(_) => fail("expected a mismatch")
    Err(msg) => @test.assert_eq(msg, "type: \"code\": expected Int, got String")
  }
}

///|
test "check_json_type rejects null where a string is required" {
  match @assert.check_json_type("{\"name\":null}", "name", type_of("String")) {
    Ok(_) => fail("expected a mismatch")
    Err(msg) =>
      @test.assert_eq(msg, "type: \"name\": expected String, got Null")
  }
}

///|
test "check_json_type reports a missing path" {
  match @assert.check_json_type("{\"code\":0}", "data.code", type_of("Int")) {
    Ok(_) => fail("expected a missing path to be reported")
    Err(msg) =>
      @test.assert_eq(msg, "type: \"data.code\" not found in the response body")
  }
}

///|
test "check_json_type rejects a body that is not json" {
  match @assert.check_json_type("nope", "code", type_of("Int")) {
    Ok(_) => fail("expected an invalid body to be rejected")
    Err(msg) => @test.assert_eq(msg.has_prefix("type: "), true)
  }
}

// ---------------------------------------------------------------------------
// duration_ms
// ---------------------------------------------------------------------------

///|
/// Parse a `duration_ms` budget out of a one-line `.probe` source, so that the
/// test does not have to build the AST by hand.
fn duration_of(op : String, limit : Int) -> @parser.DurationCheck raise {
  let source = "name: \"budget\"\nrequest:\n  url: \"https://a.test\"\nexpect:\n  status: 200\n  duration_ms \{op} \{limit}\n"
  match expect_of(source).duration {
    Some(budget) => budget
    None => fail("the budget should have been parsed")
  }
}

///|
test "check_duration accepts a duration below a strict bound" {
  let budget = duration_of("<", 500)
  match @assert.check_duration(budget, 40UL) {
    Ok(_) => ()
    Err(msg) => fail("expected the budget to hold, got \{msg}")
  }
}

///|
test "check_duration rejects a duration equal to a strict bound" {
  let budget = duration_of("<", 500)
  match @assert.check_duration(budget, 500UL) {
    Ok(_) => fail("a strict bound excludes its own limit")
    Err(msg) => @test.assert_eq(msg, "duration: expected < 500 ms, took 500 ms")
  }
}

///|
test "check_duration accepts a duration equal to an inclusive bound" {
  let budget = duration_of("<=", 500)
  match @assert.check_duration(budget, 500UL) {
    Ok(_) => ()
    Err(msg) => fail("expected the budget to hold, got \{msg}")
  }
}

///|
test "check_duration rejects a duration above an inclusive bound" {
  let budget = duration_of("<=", 500)
  match @assert.check_duration(budget, 501UL) {
    Ok(_) => fail("expected the budget to be broken")
    Err(msg) =>
      @test.assert_eq(msg, "duration: expected <= 500 ms, took 501 ms")
  }
}

///|
test "check_duration accepts a lower bound" {
  let budget = duration_of(">", 10)
  match @assert.check_duration(budget, 11UL) {
    Ok(_) => ()
    Err(msg) => fail("expected the budget to hold, got \{msg}")
  }
}

///|
test "check_duration accepts an inclusive lower bound" {
  let budget = duration_of(">=", 10)
  match @assert.check_duration(budget, 10UL) {
    Ok(_) => ()
    Err(msg) => fail("expected the budget to hold, got \{msg}")
  }
}

///|
test "check_duration accepts an exact bound" {
  let budget = duration_of("==", 250)
  match @assert.check_duration(budget, 250UL) {
    Ok(_) => ()
    Err(msg) => fail("expected the budget to hold, got \{msg}")
  }
}

///|
test "check_duration accepts any duration different from a bound" {
  let budget = duration_of("!=", 250)
  match @assert.check_duration(budget, 251UL) {
    Ok(_) => ()
    Err(msg) => fail("expected the budget to hold, got \{msg}")
  }
}

///|
test "check_duration treats a clock that went backwards as fast enough" {
  let budget = duration_of("<", 500)
  match @assert.check_duration(budget, 0UL) {
    Ok(_) => ()
    Err(msg) => fail("expected the budget to hold, got \{msg}")
  }
}

// ---------------------------------------------------------------------------
// schema
// ---------------------------------------------------------------------------

///|
/// The schema block used by the structural tests.
const FX_SCHEMA : String =
  #|name: "shape"
  #|request:
  #|  url: "https://a.test/shape"
  #|expect:
  #|  status: 200
  #|  schema:
  #|    id: int!
  #|    name: string
  #|    profile: object!
  #|      email: string!
  #|      age: int
  #|    tags: array
  #|

///|
test "check_schema accepts a conforming body" {
  let fields = expect_of(FX_SCHEMA).schema
  let body = "{\"id\":1,\"name\":\"alice\",\"profile\":{\"email\":\"a@b.c\",\"age\":30},\"tags\":[\"x\"]}"
  let failures = @assert.check_schema(body, fields)
  @test.assert_eq(failures.length(), 0)
}

///|
test "check_schema accepts a body that omits every optional field" {
  let fields = expect_of(FX_SCHEMA).schema
  let failures = @assert.check_schema(
    "{\"id\":1,\"profile\":{\"email\":\"a@b.c\"}}", fields,
  )
  @test.assert_eq(failures.length(), 0)
}

///|
test "check_schema reports a missing required field" {
  let fields = expect_of(FX_SCHEMA).schema
  let failures = @assert.check_schema(
    "{\"profile\":{\"email\":\"a@b.c\"}}", fields,
  )
  @test.assert_eq(failures.length(), 1)
  @test.assert_eq(failures[0], "schema: \"id\" is required but missing")
}

///|
test "check_schema reports a field of the wrong type" {
  let fields = expect_of(FX_SCHEMA).schema
  let failures = @assert.check_schema(
    "{\"id\":\"1\",\"profile\":{\"email\":\"a@b.c\"}}", fields,
  )
  @test.assert_eq(failures.length(), 1)
  @test.assert_eq(failures[0], "schema: \"id\": expected Int, got String")
}

///|
test "check_schema reports a nested field with its dotted path" {
  let fields = expect_of(FX_SCHEMA).schema
  let failures = @assert.check_schema(
    "{\"id\":1,\"profile\":{\"age\":30}}", fields,
  )
  @test.assert_eq(failures.length(), 1)
  @test.assert_eq(
    failures[0],
    "schema: \"profile.email\" is required but missing",
  )
}

///|
test "check_schema reports a nested field of the wrong type" {
  let fields = expect_of(FX_SCHEMA).schema
  let failures = @assert.check_schema(
    "{\"id\":1,\"profile\":{\"email\":7}}", fields,
  )
  @test.assert_eq(failures.length(), 1)
  @test.assert_eq(
    failures[0],
    "schema: \"profile.email\": expected String, got Int",
  )
}

///|
test "check_schema reports an object field that is not an object" {
  let fields = expect_of(FX_SCHEMA).schema
  let failures = @assert.check_schema("{\"id\":1,\"profile\":\"none\"}", fields)
  @test.assert_eq(failures.length(), 1)
  @test.assert_eq(
    failures[0],
    "schema: \"profile\": expected Object, got String",
  )
}

///|
test "check_schema reports every problem of a body at once" {
  let fields = expect_of(FX_SCHEMA).schema
  let failures = @assert.check_schema("{\"id\":\"1\",\"tags\":{}}", fields)
  @test.assert_eq(failures.length(), 3)
  @test.assert_eq(failures[0], "schema: \"id\": expected Int, got String")
  @test.assert_eq(failures[1], "schema: \"profile\" is required but missing")
  @test.assert_eq(failures[2], "schema: \"tags\": expected Array, got Object")
}

///|
test "check_schema rejects a body that is not an object" {
  let fields = expect_of(FX_SCHEMA).schema
  let failures = @assert.check_schema("[1,2]", fields)
  @test.assert_eq(failures.length(), 1)
  @test.assert_eq(failures[0], "schema: body: expected an Object, got Array")
}

///|
test "check_schema rejects a body that is not json" {
  let fields = expect_of(FX_SCHEMA).schema
  let failures = @assert.check_schema("not json", fields)
  @test.assert_eq(failures.length(), 1)
  @test.assert_eq(failures[0].has_prefix("schema: response body"), true)
}

///|
/// A case that declares no schema at all.
const FX_NO_SCHEMA : String =
  #|name: "no schema"
  #|request:
  #|  url: "https://a.test"
  #|expect:
  #|  status: 200
  #|

///|
test "check_schema accepts any body when no schema was declared" {
  let fields = expect_of(FX_SCHEMA).schema
  @test.assert_eq(fields.length(), 4)
  let empty = expect_of(FX_NO_SCHEMA).schema
  @test.assert_eq(@assert.check_schema("anything", empty).length(), 0)
}

// ---------------------------------------------------------------------------
// check_expect over the extended families
// ---------------------------------------------------------------------------

///|
/// A case that uses every expectation family, all of them satisfiable.
const FX_ALL_FAMILIES : String =
  #|name: "all families"
  #|request:
  #|  url: "https://a.test/all"
  #|expect:
  #|  status: 200
  #|  contains: "ok"
  #|  contains_ci: "OK"
  #|  duration_ms < 500
  #|  json:
  #|    code: 0
  #|  length:
  #|    data.items: 2
  #|  type:
  #|    code: Int
  #|    data.name: string
  #|  schema:
  #|    code: int!
  #|    ok: bool!
  #|    data: object!
  #|      name: string!
  #|      items: array!
  #|

///|
test "check_expect passes when every family holds" {
  let expect = expect_of(FX_ALL_FAMILIES)
  let body = "{\"code\":0,\"ok\":true,\"data\":{\"name\":\"alice\",\"items\":[1,2]}}"
  let failures = @assert.check_expect(expect, 200, body, 40UL)
  @test.assert_eq(failures.length(), 0)
}

///|
/// A case in which exactly one expectation of every family is broken by the
/// conforming body below.
const FX_ONE_FAILURE_EACH : String =
  #|name: "one failure each"
  #|request:
  #|  url: "https://a.test/each"
  #|expect:
  #|  status: 500
  #|  contains: "nope"
  #|  duration_ms < 1
  #|  json:
  #|    code: 0
  #|  length:
  #|    data.items: 9
  #|  type:
  #|    code: String
  #|  schema:
  #|    missing: string!
  #|

///|
/// A case whose only expectations are structural.
const FX_STRUCTURAL : String =
  #|name: "structural"
  #|request:
  #|  url: "https://a.test/structural"
  #|expect:
  #|  status: 200
  #|  length:
  #|    data.items: 2
  #|  type:
  #|    code: Int
  #|  schema:
  #|    code: int!
  #|

///|
test "check_expect collects one failure from every family" {
  let expect = expect_of(FX_ONE_FAILURE_EACH)
  let body = "{\"code\":0,\"ok\":true,\"data\":{\"name\":\"alice\",\"items\":[1,2]}}"
  // Only the declared expectations break: the `json:` one still holds against
  // the very same body.
  let failures = @assert.check_expect(expect, 200, body, 50UL)
  @test.assert_eq(failures.length(), 6)
  @test.assert_eq(failures[0], "status: expected 500, got 200")
  @test.assert_eq(failures[1], "contains: body does not contain \"nope\"")
  @test.assert_eq(failures[2], "duration: expected < 1 ms, took 50 ms")
  @test.assert_eq(
    failures[3],
    "length: \"data.items\": expected 9 elements, got 2",
  )
  @test.assert_eq(failures[4], "type: \"code\": expected String, got Int")
  @test.assert_eq(failures[5], "schema: \"missing\" is required but missing")
}

///|
test "check_expect reports an undecodable body once per structural family" {
  let expect = expect_of(FX_STRUCTURAL)
  // A body that cannot be decoded makes each structural expectation fail with
  // the decoding message rather than with a confusing per-field one.
  let failures = @assert.check_expect(expect, 200, "not json", 10UL)
  @test.assert_eq(failures.length(), 3)
  @test.assert_eq(
    failures[0].has_prefix(
      "length: \"data.items\": response body is not valid json",
    ),
    true,
  )
  @test.assert_eq(
    failures[1].has_prefix("type: \"code\": response body is not valid json"),
    true,
  )
  @test.assert_eq(
    failures[2].has_prefix("schema: response body is not valid json"),
    true,
  )
}
