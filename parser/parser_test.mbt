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

///|
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

///|
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

///|
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

///|
/// A case that omits `method:` and must therefore default to GET.
const FX_DEFAULT_METHOD : String =
  #|name: "ping"
  #|request:
  #|  url: "https://a.api.test/ping"
  #|expect:
  #|  status: 204
  #|

///|
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

///|
/// Same shape as `FX_DEFAULT_METHOD`, indented with tabs.
const FX_TAB_INDENT : String = "name: tabbed\nrequest:\n\turl: \"https://a.api.test/tab\"\nexpect:\n\tstatus: 204\n"

///|
/// A case that extracts a variable with the inline `set:` form.
const FX_SET_INLINE : String =
  #|name: login
  #|request:
  #|  method: POST
  #|  url: "https://a.api.test/login"
  #|expect:
  #|  status: 200
  #|  set: token = data.access_token
  #|

///|
/// A case that extracts two variables with the block `set:` form.
const FX_SET_BLOCK : String =
  #|name: profile
  #|request:
  #|  url: "https://a.api.test/profile"
  #|expect:
  #|  status: 200
  #|  set:
  #|    userId: data.user.id
  #|    token: data.access_token
  #|

// ---------------------------------------------------------------------------
// Invalid fixtures
// ---------------------------------------------------------------------------

///|
/// No case at all.
const FX_EMPTY : String = ""

///|
/// A case name without any request block.
const FX_ERR_NO_REQUEST : String = "name: lonely\n"

///|
/// A request block that never declares `url:`.
const FX_ERR_NO_URL : String =
  #|name: x
  #|request:
  #|  method: GET
  #|expect:
  #|  status: 200
  #|

///|
/// A request block without an expect block.
const FX_ERR_NO_EXPECT : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|

///|
/// A non-numeric status code.
const FX_ERR_BAD_STATUS : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: not-a-number
  #|

///|
/// A top-level line that is indented.
const FX_ERR_TOP_LEVEL_INDENT : String = "  name: x\n"

///|
/// An empty case name.
const FX_ERR_EMPTY_NAME : String = "name:\n"

///|
/// An unknown field inside the request block.
const FX_ERR_UNKNOWN_FIELD : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|  methd: GET
  #|expect:
  #|  status: 200
  #|

///|
/// A line that is not a `key: value` pair at all.
const FX_ERR_NO_COLON : String = "this line has no colon\n"

///|
/// An inline `set:` without the `name = json.path` assignment.
const FX_ERR_SET_NO_ASSIGN : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: 200
  #|  set: token
  #|

///|
/// A block `set:` that declares no children.
const FX_ERR_SET_EMPTY_BLOCK : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: 200
  #|  set:
  #|

// ---------------------------------------------------------------------------
// Lexer tests
// ---------------------------------------------------------------------------

///|
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

///|
test "lex keeps unquoted values verbatim" {
  let lines = match lex("  Authorization: Bearer abc\n") {
    Ok(v) => v
    Err(_) => fail("lex should succeed")
  }
  @test.assert_eq(lines[0].key, "Authorization")
  @test.assert_eq(lines[0].indent, 2)
  @test.assert_eq(lines[0].value.unwrap_or(""), "Bearer abc")
}

///|
test "lex strips matching quotes from a value" {
  let lines = match lex("url: \"https://api.example.com\"\n") {
    Ok(v) => v
    Err(_) => fail("lex should succeed")
  }
  @test.assert_eq(lines[0].value.unwrap_or(""), "https://api.example.com")
}

///|
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

///|
test "lex counts a tab as two columns of indentation" {
  let lines = match lex("\turl: x\n") {
    Ok(v) => v
    Err(_) => fail("lex should succeed")
  }
  @test.assert_eq(lines[0].indent, 2)
  @test.assert_eq(lines[0].value.unwrap_or(""), "x")
}

///|
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

///|
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

///|
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

///|
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

///|
test "parse defaults the method to GET when omitted" {
  let suite = match parse(FX_DEFAULT_METHOD) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  @test.assert_eq(suite.cases[0].request.http_method, "GET")
}

///|
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

///|
test "parse accepts tab indentation" {
  let suite = match parse(FX_TAB_INDENT) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  @test.assert_eq(suite.cases[0].request.url, "https://a.api.test/tab")
  @test.assert_eq(suite.cases[0].expect.status.unwrap_or(-1), 204)
}

///|
test "parse reads an inline set directive" {
  let suite = match parse(FX_SET_INLINE) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  let e = suite.cases[0].expect
  @test.assert_eq(e.sets.length(), 1)
  @test.assert_eq(e.sets[0].name, "token")
  @test.assert_eq(e.sets[0].path, "data.access_token")
}

///|
test "parse reads a block set directive" {
  let suite = match parse(FX_SET_BLOCK) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  let e = suite.cases[0].expect
  @test.assert_eq(e.sets.length(), 2)
  @test.assert_eq(e.sets[0].name, "userId")
  @test.assert_eq(e.sets[0].path, "data.user.id")
  @test.assert_eq(e.sets[1].name, "token")
  @test.assert_eq(e.sets[1].path, "data.access_token")
}

///|
test "parse leaves sets empty when no set directive is present" {
  let suite = match parse(FX_DEFAULT_METHOD) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  @test.assert_eq(suite.cases[0].expect.sets.length(), 0)
}

// ---------------------------------------------------------------------------
// Parser: invalid fixtures
// ---------------------------------------------------------------------------

///|
test "parse rejects an empty suite" {
  match parse(FX_EMPTY) {
    Err(_) => ()
    Ok(_) => fail("should reject empty source")
  }
}

///|
test "parse rejects a case without a request block" {
  match parse(FX_ERR_NO_REQUEST) {
    Err(_) => ()
    Ok(_) => fail("should reject case without request")
  }
}

///|
test "parse rejects a request without a url" {
  match parse(FX_ERR_NO_URL) {
    Err(_) => ()
    Ok(_) => fail("should reject request without url")
  }
}

///|
test "parse rejects a case without an expect block" {
  match parse(FX_ERR_NO_EXPECT) {
    Err(_) => ()
    Ok(_) => fail("should reject case without expect")
  }
}

///|
test "parse rejects a non-numeric status code" {
  match parse(FX_ERR_BAD_STATUS) {
    Err(_) => ()
    Ok(_) => fail("should reject invalid status")
  }
}

///|
test "parse rejects indentation at top level" {
  match parse(FX_ERR_TOP_LEVEL_INDENT) {
    Err(_) => ()
    Ok(_) => fail("should reject indented top-level line")
  }
}

///|
test "parse rejects an empty case name" {
  match parse(FX_ERR_EMPTY_NAME) {
    Err(_) => ()
    Ok(_) => fail("should reject empty case name")
  }
}

///|
test "parse rejects an unknown request field" {
  match parse(FX_ERR_UNKNOWN_FIELD) {
    Err(_) => ()
    Ok(_) => fail("should reject unknown request field")
  }
}

///|
test "parse rejects an inline set without an assignment" {
  match parse(FX_ERR_SET_NO_ASSIGN) {
    Err(_) => ()
    Ok(_) => fail("should reject set without an assignment")
  }
}

///|
test "parse rejects an empty set block" {
  match parse(FX_ERR_SET_EMPTY_BLOCK) {
    Err(_) => ()
    Ok(_) => fail("should reject an empty set block")
  }
}

// ---------------------------------------------------------------------------
// Extended expectations: contains / length / type / duration_ms / schema
// ---------------------------------------------------------------------------

///|
/// A case that uses every new expectation family at once.
const FX_EXPECT_FULL : String =
  #|name: "extended expect"
  #|request:
  #|  url: "https://a.api.test/full"
  #|expect:
  #|  status: 200
  #|  contains: "ok"
  #|  contains_ci: "OK"
  #|  duration_ms < 500
  #|  json:
  #|    code: 0
  #|  length:
  #|    data.items: 3
  #|  type:
  #|    code: Int
  #|    data.name: string
  #|  schema:
  #|    id: int!
  #|    name: string
  #|    profile: object
  #|      email: string!
  #|      age: int
  #|    tags: array
  #|

///|
/// A body budget written in the key/value form, with a two-character operator.
const FX_DURATION_COLON : String =
  #|name: "colon budget"
  #|request:
  #|  url: "https://a.api.test/budget"
  #|expect:
  #|  status: 200
  #|  duration_ms: <= 120
  #|

///|
/// An inline `length:` applying to the body root.
const FX_LENGTH_ROOT : String =
  #|name: "root length"
  #|request:
  #|  url: "https://a.api.test/list"
  #|expect:
  #|  status: 200
  #|  length: 4
  #|

///|
/// An inline `type:` applying to the body root.
const FX_TYPE_ROOT : String =
  #|name: "root type"
  #|request:
  #|  url: "https://a.api.test/list"
  #|expect:
  #|  status: 200
  #|  type: array
  #|

///|
/// A schema using the OAuth2 profile shape an access token response has.
const FX_SCHEMA_ONLY : String =
  #|name: "schema only"
  #|request:
  #|  url: "https://a.api.test/oauth/token"
  #|expect:
  #|  status: 200
  #|  schema:
  #|    access_token: string!
  #|    token_type: string!
  #|    expires_in: int!
  #|    scope: string
  #|

///|
/// `contains:` without the text to look for.
const FX_ERR_CONTAINS_NO_VALUE : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: 200
  #|  contains:
  #|

///|
/// A `length:` block whose size is not a number.
const FX_ERR_LENGTH_NOT_INT : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: 200
  #|  length:
  #|    data.items: many
  #|

///|
/// A negative `length:`, which no array can satisfy.
const FX_ERR_LENGTH_NEGATIVE : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: 200
  #|  length: -1
  #|

///|
/// A `length:` block without any child.
const FX_ERR_LENGTH_EMPTY_BLOCK : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: 200
  #|  length:
  #|

///|
/// A `type:` block naming a type that does not exist.
const FX_ERR_TYPE_UNKNOWN : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: 200
  #|  type:
  #|    code: numberr
  #|

///|
/// A `type:` block without any child.
const FX_ERR_TYPE_EMPTY_BLOCK : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: 200
  #|  type:
  #|

///|
/// `duration_ms` without an operator or a bound.
const FX_ERR_DURATION_BARE : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: 200
  #|  duration_ms:
  #|

///|
/// `duration_ms` with a comparison that is not an operator and a number.
const FX_ERR_DURATION_BAD_OP : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: 200
  #|  duration_ms < fast
  #|

///|
/// A negative duration budget, which every request would satisfy.
const FX_ERR_DURATION_NEGATIVE : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: 200
  #|  duration_ms < -1
  #|

///|
/// A `schema:` written inline instead of as a block.
const FX_ERR_SCHEMA_INLINE : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: 200
  #|  schema: object
  #|

///|
/// A `schema:` block without any field.
const FX_ERR_SCHEMA_EMPTY : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: 200
  #|  schema:
  #|

///|
/// A schema field written without a type.
const FX_ERR_SCHEMA_NO_TYPE : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: 200
  #|  schema:
  #|    id:
  #|

///|
/// A schema field naming a type that does not exist.
const FX_ERR_SCHEMA_BAD_TYPE : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: 200
  #|  schema:
  #|    id: integerr!
  #|

///|
/// A scalar schema field that tries to declare nested fields.
const FX_ERR_SCHEMA_NESTED_SCALAR : String =
  #|name: x
  #|request:
  #|  url: "https://a.api.test"
  #|expect:
  #|  status: 200
  #|  schema:
  #|    id: int
  #|      inner: string
  #|

///|
test "parse reads contains expectations, case-sensitive and folded" {
  let suite = match parse(FX_EXPECT_FULL) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  let e = suite.cases[0].expect
  @test.assert_eq(e.contains.length(), 2)
  @test.assert_eq(e.contains[0].needle, "ok")
  @test.assert_eq(e.contains[0].ignore_case, false)
  @test.assert_eq(e.contains[1].needle, "OK")
  @test.assert_eq(e.contains[1].ignore_case, true)
}

///|
test "parse reads a duration budget written as a bare comparison" {
  let suite = match parse(FX_EXPECT_FULL) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  let budget = match suite.cases[0].expect.duration {
    Some(d) => d
    None => fail("a duration budget should have been parsed")
  }
  @test.assert_eq(budget.op, "<")
  @test.assert_eq(budget.limit_ms, 500)
}

///|
test "parse reads a duration budget written as a key/value pair" {
  let suite = match parse(FX_DURATION_COLON) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  let budget = match suite.cases[0].expect.duration {
    Some(d) => d
    None => fail("a duration budget should have been parsed")
  }
  @test.assert_eq(budget.op, "<=")
  @test.assert_eq(budget.limit_ms, 120)
}

///|
test "parse reads a length block" {
  let suite = match parse(FX_EXPECT_FULL) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  let lengths = suite.cases[0].expect.lengths
  @test.assert_eq(lengths.length(), 1)
  @test.assert_eq(lengths[0].path, "data.items")
  @test.assert_eq(lengths[0].size, 3)
}

///|
test "parse reads an inline length for the body root" {
  let suite = match parse(FX_LENGTH_ROOT) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  let lengths = suite.cases[0].expect.lengths
  @test.assert_eq(lengths.length(), 1)
  @test.assert_eq(lengths[0].path, "")
  @test.assert_eq(lengths[0].size, 4)
}

///|
test "parse reads a type block and normalises type names" {
  let suite = match parse(FX_EXPECT_FULL) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  let types = suite.cases[0].expect.types
  @test.assert_eq(types.length(), 2)
  @test.assert_eq(types[0].path, "code")
  @test.assert_eq(types[0].expected.label(), "Int")
  @test.assert_eq(types[1].path, "data.name")
  @test.assert_eq(types[1].expected.label(), "String")
}

///|
test "parse reads an inline type for the body root" {
  let suite = match parse(FX_TYPE_ROOT) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  let types = suite.cases[0].expect.types
  @test.assert_eq(types.length(), 1)
  @test.assert_eq(types[0].path, "")
  @test.assert_eq(types[0].expected.label(), "Array")
}

///|
test "parse reads a nested schema" {
  let suite = match parse(FX_EXPECT_FULL) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  let schema = suite.cases[0].expect.schema
  @test.assert_eq(schema.length(), 4)
  @test.assert_eq(schema[0].name, "id")
  @test.assert_eq(schema[0].required, true)
  @test.assert_eq(schema[0].field_type.label(), "Int")
  @test.assert_eq(schema[0].children.length(), 0)
  @test.assert_eq(schema[1].name, "name")
  @test.assert_eq(schema[1].required, false)
  @test.assert_eq(schema[2].name, "profile")
  @test.assert_eq(schema[2].field_type.label(), "Object")
  @test.assert_eq(schema[2].children.length(), 2)
  @test.assert_eq(schema[2].children[0].name, "email")
  @test.assert_eq(schema[2].children[0].required, true)
  @test.assert_eq(schema[2].children[0].field_type.label(), "String")
  @test.assert_eq(schema[2].children[1].name, "age")
  @test.assert_eq(schema[2].children[1].required, false)
  @test.assert_eq(schema[3].name, "tags")
  @test.assert_eq(schema[3].field_type.label(), "Array")
}

///|
test "parse reads a flat schema of required fields" {
  let suite = match parse(FX_SCHEMA_ONLY) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  let schema = suite.cases[0].expect.schema
  @test.assert_eq(schema.length(), 4)
  @test.assert_eq(schema[0].name, "access_token")
  @test.assert_eq(schema[0].required, true)
  @test.assert_eq(schema[0].field_type.label(), "String")
  @test.assert_eq(schema[2].required, true)
  @test.assert_eq(schema[2].field_type.label(), "Int")
  @test.assert_eq(schema[3].required, false)
}

///|
test "parse leaves the extended expectations empty when unused" {
  let suite = match parse(FX_DEFAULT_METHOD) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  let e = suite.cases[0].expect
  @test.assert_eq(e.contains.length(), 0)
  @test.assert_eq(e.lengths.length(), 0)
  @test.assert_eq(e.types.length(), 0)
  @test.assert_eq(e.schema.length(), 0)
  match e.duration {
    None => ()
    Some(_) => fail("no duration budget should have been parsed")
  }
}

///|
test "parse rejects contains without a value" {
  match parse(FX_ERR_CONTAINS_NO_VALUE) {
    Err(_) => ()
    Ok(_) => fail("should reject contains without a value")
  }
}

///|
test "parse rejects a non-numeric length" {
  match parse(FX_ERR_LENGTH_NOT_INT) {
    Err(_) => ()
    Ok(_) => fail("should reject a non-numeric length")
  }
}

///|
test "parse rejects a negative length" {
  match parse(FX_ERR_LENGTH_NEGATIVE) {
    Err(_) => ()
    Ok(_) => fail("should reject a negative length")
  }
}

///|
test "parse rejects an empty length block" {
  match parse(FX_ERR_LENGTH_EMPTY_BLOCK) {
    Err(_) => ()
    Ok(_) => fail("should reject an empty length block")
  }
}

///|
test "parse rejects an unknown type name" {
  match parse(FX_ERR_TYPE_UNKNOWN) {
    Err(_) => ()
    Ok(_) => fail("should reject an unknown type name")
  }
}

///|
test "parse rejects an empty type block" {
  match parse(FX_ERR_TYPE_EMPTY_BLOCK) {
    Err(_) => ()
    Ok(_) => fail("should reject an empty type block")
  }
}

///|
test "parse rejects duration_ms without a budget" {
  match parse(FX_ERR_DURATION_BARE) {
    Err(_) => ()
    Ok(_) => fail("should reject a bare duration_ms")
  }
}

///|
test "parse rejects a duration comparison without a number" {
  match parse(FX_ERR_DURATION_BAD_OP) {
    Err(_) => ()
    Ok(_) => fail("should reject a duration comparison without a number")
  }
}

///|
test "parse rejects a negative duration budget" {
  match parse(FX_ERR_DURATION_NEGATIVE) {
    Err(_) => ()
    Ok(_) => fail("should reject a negative duration budget")
  }
}

///|
test "parse rejects an inline schema" {
  match parse(FX_ERR_SCHEMA_INLINE) {
    Err(_) => ()
    Ok(_) => fail("should reject an inline schema")
  }
}

///|
test "parse rejects an empty schema block" {
  match parse(FX_ERR_SCHEMA_EMPTY) {
    Err(_) => ()
    Ok(_) => fail("should reject an empty schema block")
  }
}

///|
test "parse rejects a schema field without a type" {
  match parse(FX_ERR_SCHEMA_NO_TYPE) {
    Err(_) => ()
    Ok(_) => fail("should reject a schema field without a type")
  }
}

///|
test "parse rejects an unknown schema type" {
  match parse(FX_ERR_SCHEMA_BAD_TYPE) {
    Err(_) => ()
    Ok(_) => fail("should reject an unknown schema type")
  }
}

///|
test "parse rejects nested fields under a scalar schema field" {
  match parse(FX_ERR_SCHEMA_NESTED_SCALAR) {
    Err(_) => ()
    Ok(_) => fail("should reject nesting under a scalar field")
  }
}

// ---------------------------------------------------------------------------
// Lexer: escapes and bare comparisons
// ---------------------------------------------------------------------------

///|
test "lex decodes the escape sequences of a quoted value" {
  let lines = match lex("body: \"a\\nb\\t\\\"c\\\\d\"\n") {
    Ok(v) => v
    Err(msg) => fail("lex should succeed: \{msg}")
  }
  @test.assert_eq(lines[0].key, "body")
  @test.assert_eq(lines[0].value.unwrap_or(""), "a\nb\t\"c\\d")
}

///|
test "lex keeps an unknown escape sequence verbatim" {
  let lines = match lex("x: \"a\\qb\"\n") {
    Ok(v) => v
    Err(msg) => fail("lex should succeed: \{msg}")
  }
  @test.assert_eq(lines[0].value.unwrap_or(""), "a\\qb")
}

///|
test "lex leaves an unquoted backslash alone" {
  let lines = match lex("path: C:\\temp\\new\n") {
    Ok(v) => v
    Err(msg) => fail("lex should succeed: \{msg}")
  }
  @test.assert_eq(lines[0].value.unwrap_or(""), "C:\\temp\\new")
}

///|
test "lex recognises a bare comparison expression" {
  let lines = match lex("  duration_ms < 500\n") {
    Ok(v) => v
    Err(msg) => fail("lex should succeed: \{msg}")
  }
  @test.assert_eq(lines[0].key, "duration_ms")
  @test.assert_eq(lines[0].indent, 2)
  @test.assert_eq(lines[0].value.unwrap_or(""), "< 500")
}

///|
test "lex recognises a two-character comparison operator" {
  let lines = match lex("duration_ms >= 10\n") {
    Ok(v) => v
    Err(msg) => fail("lex should succeed: \{msg}")
  }
  @test.assert_eq(lines[0].value.unwrap_or(""), ">= 10")
}

///|
test "lex still rejects a bare assignment" {
  match lex("total = 5\n") {
    Err(_) => ()
    Ok(_) => fail("a bare assignment is not a comparison expression")
  }
}

// ---------------------------------------------------------------------------
// Suite-level config block
// ---------------------------------------------------------------------------

///|
/// A file that opens with a full `config:` preamble.
const FX_CONFIG_FULL : String =
  #|config:
  #|  base_url: "https://api.example.com/v1"
  #|  global_timeout: 8000
  #|  global_headers:
  #|    Authorization: "Bearer ${API_TOKEN}"
  #|    Accept: "application/json"
  #|name: "configured"
  #|request:
  #|  url: "/users"
  #|expect:
  #|  status: 200
  #|

///|
/// A config block that only declares a base URL.
const FX_CONFIG_BASE_ONLY : String =
  #|config:
  #|  base_url: "https://api.example.com"
  #|name: "base only"
  #|request:
  #|  url: "/users"
  #|expect:
  #|  status: 200
  #|

///|
test "parse reads a full config block" {
  let suite = match parse(FX_CONFIG_FULL) {
    Ok(v) => v
    Err(msg) => fail("config fixture should parse: \{msg}")
  }
  @test.assert_eq(
    suite.config.base_url.unwrap_or(""),
    "https://api.example.com/v1",
  )
  @test.assert_eq(suite.config.global_timeout_ms.unwrap_or(-1), 8000)
  @test.assert_eq(suite.config.is_empty(), false)
  @test.assert_eq(suite.cases.length(), 1)
}

///|
test "parse keeps the global headers in declaration order" {
  let suite = match parse(FX_CONFIG_FULL) {
    Ok(v) => v
    Err(msg) => fail("config fixture should parse: \{msg}")
  }
  @test.assert_eq(suite.config.global_headers.length(), 2)
  @test.assert_eq(suite.config.global_headers[0].key, "Authorization")
  // A config value is stored verbatim: only the runner expands placeholders.
  @test.assert_eq(suite.config.global_headers[0].value, "Bearer ${API_TOKEN}")
  @test.assert_eq(suite.config.global_headers[1].key, "Accept")
  @test.assert_eq(suite.config.global_headers[1].value, "application/json")
}

///|
test "parse defaults to the empty config when no block is declared" {
  let suite = match parse(FX_GET_FULL) {
    Ok(v) => v
    Err(msg) => fail("fixture should parse: \{msg}")
  }
  @test.assert_eq(suite.config.is_empty(), true)
  @test.assert_eq(suite.config.base_url.unwrap_or(""), "")
  @test.assert_eq(suite.config.global_headers.length(), 0)
}

///|
test "parse leaves the global timeout unset when only base_url is declared" {
  let suite = match parse(FX_CONFIG_BASE_ONLY) {
    Ok(v) => v
    Err(msg) => fail("config fixture should parse: \{msg}")
  }
  @test.assert_eq(suite.config.global_timeout_ms.unwrap_or(-1), -1)
  @test.assert_eq(suite.config.is_empty(), false)
}

///|
test "parse reads a case-level timeout" {
  let src =
    #|name: "slow"
    #|request:
    #|  url: "https://api.example.com/slow"
    #|  timeout: 250
    #|expect:
    #|  status: 200
    #|
  let suite = match parse(src) {
    Ok(v) => v
    Err(msg) => fail("fixture should parse: \{msg}")
  }
  @test.assert_eq(suite.cases[0].request.timeout_ms.unwrap_or(-1), 250)
}

///|
test "parse leaves the case timeout unset when it is omitted" {
  let suite = match parse(FX_CONFIG_BASE_ONLY) {
    Ok(v) => v
    Err(msg) => fail("fixture should parse: \{msg}")
  }
  @test.assert_eq(suite.cases[0].request.timeout_ms.unwrap_or(-1), -1)
}

///|
test "parse rejects a config block declared after the first case" {
  let src =
    #|name: "first"
    #|request:
    #|  url: "https://api.example.com/users"
    #|expect:
    #|  status: 200
    #|config:
    #|  base_url: "https://api.example.com"
    #|
  match parse(src) {
    Err(msg) =>
      @test.assert_eq(msg.contains("must appear before the first case"), true)
    Ok(_) => fail("a trailing config block must be rejected")
  }
}

///|
test "parse rejects a duplicate config block" {
  let src =
    #|config:
    #|  base_url: "https://api.example.com"
    #|config:
    #|  base_url: "https://other.example.com"
    #|name: "dup"
    #|request:
    #|  url: "/users"
    #|expect:
    #|  status: 200
    #|
  match parse(src) {
    Err(msg) => @test.assert_eq(msg.contains("duplicate config block"), true)
    Ok(_) => fail("a second config block must be rejected")
  }
}

///|
test "parse rejects an empty config block" {
  match parse("config:\nname: \"x\"\n") {
    Err(msg) => @test.assert_eq(msg.contains("config block is empty"), true)
    Ok(_) => fail("an empty config block must be rejected")
  }
}

///|
test "parse rejects an unknown config key" {
  let src =
    #|config:
    #|  base_path: "https://api.example.com"
    #|
  match parse(src) {
    Err(msg) => @test.assert_eq(msg.contains("unknown config key"), true)
    Ok(_) => fail("an unknown config key must be rejected")
  }
}

///|
test "parse rejects a relative base_url" {
  let src =
    #|config:
    #|  base_url: "/v1"
    #|name: "relative base"
    #|request:
    #|  url: "/users"
    #|expect:
    #|  status: 200
    #|
  match parse(src) {
    Err(msg) =>
      @test.assert_eq(msg.contains("must be an absolute http(s) url"), true)
    Ok(_) => fail("a relative base_url must be rejected")
  }
}

///|
test "parse rejects a non-absolute config url that only looks like one" {
  let src =
    #|config:
    #|  base_url: "ftp://files.example.com"
    #|name: "ftp base"
    #|request:
    #|  url: "/users"
    #|expect:
    #|  status: 200
    #|
  match parse(src) {
    Err(msg) =>
      @test.assert_eq(msg.contains("must be an absolute http(s) url"), true)
    Ok(_) => fail("only http(s) is a usable base_url")
  }
}

///|
test "parse rejects a negative global timeout" {
  let src =
    #|config:
    #|  base_url: "https://api.example.com"
    #|  global_timeout: -1
    #|name: "negative"
    #|request:
    #|  url: "/users"
    #|expect:
    #|  status: 200
    #|
  match parse(src) {
    Err(msg) =>
      @test.assert_eq(msg.contains("global_timeout must not be negative"), true)
    Ok(_) => fail("a negative timeout must be rejected")
  }
}

///|
test "parse rejects a non-numeric global timeout" {
  let src =
    #|config:
    #|  base_url: "https://api.example.com"
    #|  global_timeout: soon
    #|name: "typo"
    #|request:
    #|  url: "/users"
    #|expect:
    #|  status: 200
    #|
  match parse(src) {
    Err(msg) => @test.assert_eq(msg.contains("invalid global_timeout"), true)
    Ok(_) => fail("a non-numeric timeout must be rejected")
  }
}

///|
test "parse rejects a negative case timeout" {
  let src =
    #|name: "negative"
    #|request:
    #|  url: "https://api.example.com/users"
    #|  timeout: -5
    #|expect:
    #|  status: 200
    #|
  match parse(src) {
    Err(msg) =>
      @test.assert_eq(msg.contains("timeout must not be negative"), true)
    Ok(_) => fail("a negative case timeout must be rejected")
  }
}

// ---------------------------------------------------------------------------
// `set:` sources: body, response header and cookie
// ---------------------------------------------------------------------------

///|
/// One case extracting from all three sources.
const FX_SET_SOURCES : String =
  #|name: "extract everything"
  #|request:
  #|  url: "https://api.example.com/login"
  #|expect:
  #|  status: 200
  #|  set: raw = data.token
  #|  set: token = header.X-Token
  #|  set: sid = cookie.session
  #|  set: uid = json.data.id
  #|

///|
test "parse reads set directives from the body, header and cookie" {
  let suite = match parse(FX_SET_SOURCES) {
    Ok(v) => v
    Err(msg) => fail("set fixture should parse: \{msg}")
  }
  let sets = suite.cases[0].expect.sets
  @test.assert_eq(sets.length(), 4)
  @test.assert_eq(sets[0].name, "raw")
  @test.assert_eq(sets[0].path, "data.token")
  match sets[0].source {
    FromBody => ()
    _ => fail("a path without a prefix reads the body")
  }
  @test.assert_eq(sets[1].name, "token")
  @test.assert_eq(sets[1].path, "X-Token")
  match sets[1].source {
    FromHeader => ()
    _ => fail("`header.` should select the response header")
  }
  @test.assert_eq(sets[2].path, "session")
  match sets[2].source {
    FromCookie => ()
    _ => fail("`cookie.` should select the cookie")
  }
  @test.assert_eq(sets[3].path, "data.id")
}

///|
test "parse folds the case of a set source prefix" {
  let src =
    #|name: "case folded"
    #|request:
    #|  url: "https://api.example.com/login"
    #|expect:
    #|  status: 200
    #|  set: token = HEADER.X-Token
    #|  set: sid = Cookies.session
    #|  set: uid = Body.data.id
    #|
  let suite = match parse(src) {
    Ok(v) => v
    Err(msg) => fail("set fixture should parse: \{msg}")
  }
  let sets = suite.cases[0].expect.sets
  match sets[0].source {
    FromHeader => ()
    _ => fail("`HEADER.` should still select the header")
  }
  match sets[1].source {
    FromCookie => ()
    _ => fail("`Cookies.` should still select the cookie")
  }
  match sets[2].source {
    FromBody => ()
    _ => fail("`Body.` should still select the body")
  }
}

///|
test "parse rejects a set prefix without a name after the dot" {
  let src =
    #|name: "empty target"
    #|request:
    #|  url: "https://api.example.com/login"
    #|expect:
    #|  status: 200
    #|  set: token = header.
    #|
  match parse(src) {
    Err(msg) =>
      @test.assert_eq(msg.contains("needs a name after the dot"), true)
    Ok(_) => fail("`header.` alone names nothing to read")
  }
}

// ---------------------------------------------------------------------------
// Trailing inline comments
// ---------------------------------------------------------------------------

///|
/// A suite whose every construct carries a trailing `#` comment: the config
/// block, the case header, the request fields and the assertions all still have
/// to lex down to exactly the same values as their uncommented twins.
const FX_INLINE_COMMENTS : String =
  #|config:                                  # suite-wide defaults
  #|  base_url: "https://a.api.test"         # relative urls resolve against it
  #|  global_timeout: 4000                   # milliseconds
  #|  global_headers:
  #|    Accept: "application/json"           # sent with every case
  #|
  #|name: "commented"                        # the case label
  #|request:
  #|  method: GET                             # the verb
  #|  url: "/users"                           # the path
  #|  headers:
  #|    X-Trace: "Bearer a#b"                 # this hash is inside quotes
  #|  query:
  #|    page: 1                               # a query parameter
  #|expect:
  #|  status: 200                             # an exact match
  #|  contains: "#tag"                        # this hash is inside quotes
  #|  duration_ms <= 3000                     # a bare comparison
  #|  set: token = data.access_token          # an extraction
  #|

///|
test "lex strips a trailing comment after a quoted value" {
  let lines = match lex("  url: \"/users\"    # the endpoint\n") {
    Ok(v) => v
    Err(msg) => fail("lex should succeed: \{msg}")
  }
  @test.assert_eq(lines[0].key, "url")
  @test.assert_eq(lines[0].indent, 2)
  @test.assert_eq(lines[0].value.unwrap_or(""), "/users")
}

///|
test "lex strips a trailing comment after a bare comparison" {
  let lines = match lex("  duration_ms <= 2000   # a generous budget\n") {
    Ok(v) => v
    Err(msg) => fail("lex should succeed: \{msg}")
  }
  @test.assert_eq(lines[0].key, "duration_ms")
  @test.assert_eq(lines[0].value.unwrap_or(""), "<= 2000")
}

///|
test "lex keeps a hash that is glued to an unquoted value" {
  let lines = match lex("url: https://a.api.test/x#frag\n") {
    Ok(v) => v
    Err(msg) => fail("lex should succeed: \{msg}")
  }
  @test.assert_eq(lines[0].value.unwrap_or(""), "https://a.api.test/x#frag")
}

///|
test "lex keeps a hash that sits inside a quoted value" {
  let lines = match lex("contains: \"#tag\"  # a real comment\n") {
    Ok(v) => v
    Err(msg) => fail("lex should succeed: \{msg}")
  }
  @test.assert_eq(lines[0].key, "contains")
  @test.assert_eq(lines[0].value.unwrap_or(""), "#tag")
}

///|
test "lex drops a comment indented deeper than the code around it" {
  let src = "expect:\n  status: 200\n        # far deeper than the fields\n  json:\n    ok: true\n"
  let lines = match lex(src) {
    Ok(v) => v
    Err(msg) => fail("lex should succeed: \{msg}")
  }
  @test.assert_eq(lines.length(), 4)
  @test.assert_eq(lines[1].key, "status")
  @test.assert_eq(lines[2].key, "json")
  @test.assert_eq(lines[3].indent, 4)
}

///|
test "parse accepts a trailing comment on every line of a suite" {
  let suite = match parse(FX_INLINE_COMMENTS) {
    Ok(v) => v
    Err(msg) => fail("parse should succeed: \{msg}")
  }
  @test.assert_eq(suite.config.base_url.unwrap_or(""), "https://a.api.test")
  @test.assert_eq(suite.config.global_timeout_ms.unwrap_or(-1), 4000)
  @test.assert_eq(suite.config.global_headers.length(), 1)
  @test.assert_eq(suite.config.global_headers[0].key, "Accept")
  @test.assert_eq(suite.config.global_headers[0].value, "application/json")
  @test.assert_eq(suite.cases.length(), 1)
  let first = suite.cases[0]
  @test.assert_eq(first.name, "commented")
  @test.assert_eq(first.request.http_method, "GET")
  @test.assert_eq(first.request.url, "/users")
  @test.assert_eq(first.request.headers[0].value, "Bearer a#b")
  @test.assert_eq(first.request.query[0].key, "page")
  @test.assert_eq(first.request.query[0].value, "1")
  @test.assert_eq(first.expect.status.unwrap_or(-1), 200)
  @test.assert_eq(first.expect.contains[0].needle, "#tag")
  @test.assert_eq(first.expect.duration.unwrap().limit_ms, 3000)
  @test.assert_eq(first.expect.duration.unwrap().op, "<=")
  @test.assert_eq(first.expect.sets[0].name, "token")
  @test.assert_eq(first.expect.sets[0].path, "data.access_token")
}
