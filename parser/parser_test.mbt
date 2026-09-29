/// MoonProbe - parser tests
///
/// Unit tests for the lexer and parser. Every `.probe` source used as an input
/// is declared as a named fixture below: the valid fixtures must parse into the
/// expected AST, the invalid ones must be rejected with an error.
///
/// The sources are kept inline instead of living in separate files because the
/// suite also runs on the `wasm-gc` backend, which has no file system.

// ---------------------------------------------------------------------------
// Valid fixtures
// ---------------------------------------------------------------------------

/// A GET case covering headers, query parameters and dotted JSON paths.
const FX_GET_FULL : String =
  #|name: "获取用户列表"
  #|request:
  #|  method: GET
  #|  url: "https://api.example.com/users"
  #|  headers:
  #|    Authorization: "Bearer token123"
  #|    Accept: "application/json"
  #|  query:
  #|    page: 1
  #|expect:
  #|  status: 200
  #|  json:
  #|    code: 0
  #|    data.count: 3
  #|

/// A POST case with a single-quoted JSON body.
const FX_POST_BODY : String =
  #|name: "create item"
  #|request:
  #|  method: POST
  #|  url: "https://api.example.com/items"
  #|  body: '{"active": true}'
  #|expect:
  #|  status: 201
  #|

/// Two cases in a single suite.
const FX_MULTI_CASE : String =
  #|name: "case one"
  #|request:
  #|  url: "https://a.api.test/1"
  #|expect:
  #|  status: 200
  #|name: "case two"
  #|request:
  #|  url: "https://b.api.test/2"
  #|expect:
  #|  status: 404
  #|

/// A case that omits `method:` and must therefore default to GET.
const FX_DEFAULT_METHOD : String =
  #|name: "ping"
  #|request:
  #|  url: "https://a.api.test/ping"
  #|expect:
  #|  status: 204
  #|

/// Same shape as `FX_GET_FULL`, indented with four spaces per level.
const FX_FOUR_SPACE_INDENT : String =
  #|name: "four spaces"
  #|request:
  #|    method: POST
  #|    url: "https://a.api.test/deep"
  #|    headers:
  #|        X-Trace: "1"
  #|expect:
  #|    status: 201
  #|    json:
  #|        ok: true
  #|

/// Same shape as `FX_DEFAULT_METHOD`, indented with tabs.
const FX_TAB_INDENT : String =
  "name: tabbed\nrequest:\n\turl: \"https://a.api.test/tab\"\nexpect:\n\tstatus: 204\n"

// ---------------------------------------------------------------------------
// Invalid fixtures
// ---------------------------------------------------------------------------

/// No case at all.
const FX_EMPTY : String = ""

/// A case name without any request block.
const FX_ERR_NO_REQUEST : String = "name: lonely\n"

/// A request block that never declares `url:`.
const FX_ERR_NO_URL : String =
  #|name: x
  #|request:
  #|  method: GET
  #|expect:
  #|  status: 200
  #|

/// A request block without an expect block.
const FX_ERR_NO_EXPECT : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|

/// A non-numeric status code.
const FX_ERR_BAD_STATUS : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: not-a-number
  #|

/// A top-level line that is indented.
const FX_ERR_TOP_LEVEL_INDENT : String = "  name: x\n"

/// An empty case name.
const FX_ERR_EMPTY_NAME : String = "name:\n"

/// An unknown field inside the request block.
const FX_ERR_UNKNOWN_FIELD : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|  methd: GET
  #|expect:
  #|  status: 200
  #|

/// A line that is not a `key: value` pair at all.
const FX_ERR_NO_COLON : String = "this line has no colon\n"

// ---------------------------------------------------------------------------
// Lexer tests
// ---------------------------------------------------------------------------

test "lex skips comments and blank lines, preserves indentation" {
  let src = "name: a\n\n  # a comment\nrequest:\n"
  let lines = match lex(src) {
    Ok(v) => v
    Err(_) => fail("lex should succeed")
  }
  @test.assert_eq(lines.length(), 2)
  @test.assert_eq(lines[0].key, "name")
  @test.assert_eq(lines[0].indent, 0)
  @test.assert_eq(lines[0].value.unwrap_or(""), "a")
  @test.assert_eq(lines[1].key, "request")
}

test "lex keeps unquoted values verbatim" {
  let lines = match lex("  Authorization: Bearer abc\n") {
    Ok(v) => v
    Err(_) => fail("lex should succeed")
  }
  @test.assert_eq(lines[0].key, "Authorization")
  @test.assert_eq(lines[0].indent, 2)
  @test.assert_eq(lines[0].value.unwrap_or(""), "Bearer abc")
}

test "lex strips matching quotes from a value" {
  let lines = match lex("url: \"https://api.example.com\"\n") {
    Ok(v) => v
    Err(_) => fail("lex should succeed")
  }
  @test.assert_eq(lines[0].value.unwrap_or(""), "https://api.example.com")
}

test "lex treats a key without a value as a block header" {
  let lines = match lex("expect:\n  status: 200\n") {
    Ok(v) => v
    Err(_) => fail("lex should succeed")
  }
  @test.assert_eq(lines[0].key, "expect")
  match lines[0].value {
    None => ()
    Some(v) => fail("expected a block header, got value \{v}")
  }
}

test "lex counts a tab as two columns of indentation" {
  let lines = match lex("\turl: x\n") {
    Ok(v) => v
    Err(_) => fail("lex should succeed")
  }
  @test.assert_eq(lines[0].indent, 2)
  @test.assert_eq(lines[0].value.unwrap_or(""), "x")
}

test "lex rejects a line without a colon" {
  let res = lex(FX_ERR_NO_COLON)
  match res {
    Err(_) => ()
    Ok(_) => fail("should reject malformed key line")
  }
}

// ---------------------------------------------------------------------------
// Parser: valid fixtures
// ---------------------------------------------------------------------------

test "parse builds a full suite with request and expect blocks" {
  let suite = match parse(FX_GET_FULL) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  @test.assert_eq(suite.cases.length(), 1)
  let c = suite.cases[0]
  @test.assert_eq(c.name, "获取用户列表")
  @test.assert_eq(c.request.http_method, "GET")
  @test.assert_eq(c.request.url, "https://api.example.com/users")
  @test.assert_eq(c.request.headers.length(), 2)
  @test.assert_eq(c.request.headers[0].key, "Authorization")
  @test.assert_eq(c.request.headers[0].value, "Bearer token123")
  @test.assert_eq(c.request.headers[1].key, "Accept")
  @test.assert_eq(c.request.query.length(), 1)
  @test.assert_eq(c.request.query[0].key, "page")
  @test.assert_eq(c.request.query[0].value, "1")
  @test.assert_eq(c.expect.status.unwrap_or(-1), 200)
  @test.assert_eq(c.expect.checks.length(), 2)
  @test.assert_eq(c.expect.checks[0].path, "code")
  @test.assert_eq(c.expect.checks[0].expected, "0")
  @test.assert_eq(c.expect.checks[1].path, "data.count")
  @test.assert_eq(c.expect.checks[1].expected, "3")
  match c.request.body {
    None => ()
    Some(b) => fail("request body should be absent, got \{b}")
  }
}

test "parse supports multiple cases in one suite" {
  let suite = match parse(FX_MULTI_CASE) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  @test.assert_eq(suite.cases.length(), 2)
  @test.assert_eq(suite.cases[0].name, "case one")
  @test.assert_eq(suite.cases[1].name, "case two")
  @test.assert_eq(suite.cases[1].expect.status.unwrap_or(-1), 404)
}

test "parse stores the request body when declared" {
  let suite = match parse(FX_POST_BODY) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  @test.assert_eq(suite.cases[0].request.http_method, "POST")
  @test.assert_eq(
    suite.cases[0].request.body.unwrap_or(""),
    "{\"active\": true}",
  )
}

test "parse defaults the method to GET when omitted" {
  let suite = match parse(FX_DEFAULT_METHOD) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  @test.assert_eq(suite.cases[0].request.http_method, "GET")
}

test "parse accepts four-space indentation" {
  let suite = match parse(FX_FOUR_SPACE_INDENT) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  let c = suite.cases[0]
  @test.assert_eq(c.request.http_method, "POST")
  @test.assert_eq(c.request.headers[0].key, "X-Trace")
  @test.assert_eq(c.expect.status.unwrap_or(-1), 201)
  @test.assert_eq(c.expect.checks[0].path, "ok")
  @test.assert_eq(c.expect.checks[0].expected, "true")
}

test "parse accepts tab indentation" {
  let suite = match parse(FX_TAB_INDENT) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  @test.assert_eq(suite.cases[0].request.url, "https://a.api.test/tab")
  @test.assert_eq(suite.cases[0].expect.status.unwrap_or(-1), 204)
}

// ---------------------------------------------------------------------------
// Parser: invalid fixtures
// ---------------------------------------------------------------------------

test "parse rejects an empty suite" {
  match parse(FX_EMPTY) {
    Err(_) => ()
    Ok(_) => fail("should reject empty source")
  }
}

test "parse rejects a case without a request block" {
  match parse(FX_ERR_NO_REQUEST) {
    Err(_) => ()
    Ok(_) => fail("should reject case without request")
  }
}

test "parse rejects a request without a url" {
  match parse(FX_ERR_NO_URL) {
    Err(_) => ()
    Ok(_) => fail("should reject request without url")
  }
}

test "parse rejects a case without an expect block" {
  match parse(FX_ERR_NO_EXPECT) {
    Err(_) => ()
    Ok(_) => fail("should reject case without expect")
  }
}

test "parse rejects a non-numeric status code" {
  match parse(FX_ERR_BAD_STATUS) {
    Err(_) => ()
    Ok(_) => fail("should reject invalid status")
  }
}

test "parse rejects indentation at top level" {
  match parse(FX_ERR_TOP_LEVEL_INDENT) {
    Err(_) => ()
    Ok(_) => fail("should reject indented top-level line")
  }
}

test "parse rejects an empty case name" {
  match parse(FX_ERR_EMPTY_NAME) {
    Err(_) => ()
    Ok(_) => fail("should reject empty case name")
  }
}

test "parse rejects an unknown request field" {
  match parse(FX_ERR_UNKNOWN_FIELD) {
    Err(_) => ()
    Ok(_) => fail("should reject unknown request field")
  }
}