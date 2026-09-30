/// MoonProbe - runner tests
///
/// Covers the pure decision logic of the runner — config merging, placeholder
/// expansion, URL building, response-header reading and `set:` extraction — so
/// these run on every backend. The transport itself is exercised separately in
/// `runner_http_test.mbt`, which is `js`-only.

///|
/// The environment lookup of a process with nothing set: used by every test that
/// does not care about `${...}`.
fn no_env(_key : String) -> String? {
  return None
}

///|
/// An environment lookup where only `API_TOKEN` is set, so that placeholder
/// tests can pin down "set" and "not set" without touching the real process.
fn env_with_api_token(key : String) -> String? {
  if key == "API_TOKEN" {
    return Some("s3cret")
  }
  return None
}

///|
/// Parse `.probe` source into the suite it declares.
fn suite_of(source : String) -> @parser.Suite raise {
  match @parser.parse(source) {
    Ok(suite) => suite
    Err(msg) => fail("fixture should parse: \{msg}")
  }
}

///|
/// Resolve the first case of `source` against its own suite config.
fn resolved_of(source : String) -> @runner.ResolvedRequest raise {
  let suite = suite_of(source)
  match @runner.resolve_request(suite.cases[0].request, suite.config) {
    Ok(resolved) => resolved
    Err(msg) => fail("request should resolve: \{msg}")
  }
}

///|
/// Build the URL of the first case of `source`.
fn url_of(
  source : String,
  context : Map[String, String],
  env : (String) -> String?,
) -> String raise {
  match @runner.build_url(resolved_of(source), context, env) {
    Ok(url) => url
    Err(msg) => fail("url should build: \{msg}")
  }
}

///|
/// Unwrap a successful resolution, failing the test on an error.
fn ok_of(result : Result[String, String]) -> String raise {
  match result {
    Ok(text) => text
    Err(msg) => fail("expected a value, got an error: \{msg}")
  }
}

///|
/// The message of a failed resolution, failing the test on a success.
fn err_of(result : Result[String, String]) -> String raise {
  match result {
    Ok(text) => fail("expected an error, got \"\{text}\"")
    Err(msg) => msg
  }
}

// ---------------------------------------------------------------------------
// URL building
// ---------------------------------------------------------------------------

///|
test "build_url leaves a url without query parameters untouched" {
  let source =
    #|name: "no query"
    #|request:
    #|  url: "https://a.test/users"
    #|expect:
    #|  status: 200
    #|
  @test.assert_eq(
    url_of(source, @runner.new_context(), no_env),
    "https://a.test/users",
  )
}

///|
test "build_url appends percent-encoded query parameters" {
  let source =
    #|name: "with query"
    #|request:
    #|  url: "https://a.test/search"
    #|  query:
    #|    q: "a b+c"
    #|    page: 1
    #|expect:
    #|  status: 200
    #|
  @test.assert_eq(
    url_of(source, @runner.new_context(), no_env),
    "https://a.test/search?q=a%20b%2Bc&page=1",
  )
}

///|
test "build_url switches to & when the url already carries a query" {
  let source =
    #|name: "already queried"
    #|request:
    #|  url: "https://a.test/search?via=cli"
    #|  query:
    #|    page: 2
    #|expect:
    #|  status: 200
    #|
  @test.assert_eq(
    url_of(source, @runner.new_context(), no_env),
    "https://a.test/search?via=cli&page=2",
  )
}

///|
test "build_url expands a bound variable in the url and query values" {
  let source =
    #|name: "interpolated"
    #|request:
    #|  url: "https://a.test/users/{{id}}/profile"
    #|  query:
    #|    token: "{{token}}"
    #|expect:
    #|  status: 200
    #|
  let context = @runner.new_context()
  context["id"] = "42"
  context["token"] = "abc def"
  @test.assert_eq(
    url_of(source, context, no_env),
    "https://a.test/users/42/profile?token=abc%20def",
  )
}

///|
test "build_url leaves an unbound placeholder verbatim" {
  let source =
    #|name: "unbound"
    #|request:
    #|  url: "https://a.test/{{missing}}"
    #|expect:
    #|  status: 200
    #|
  @test.assert_eq(
    url_of(source, @runner.new_context(), no_env),
    "https://a.test/{{missing}}",
  )
}

///|
test "build_url expands an environment variable in the url" {
  let source =
    #|name: "from the environment"
    #|request:
    #|  url: "https://a.test/{{path}}?token=${API_TOKEN}"
    #|expect:
    #|  status: 200
    #|
  let context = @runner.new_context()
  context["path"] = "users"
  @test.assert_eq(
    url_of(source, context, env_with_api_token),
    "https://a.test/users?token=s3cret",
  )
}

///|
test "build_url reports an unset environment variable with no fallback" {
  let source =
    #|name: "unset"
    #|request:
    #|  url: "https://a.test/users?token=${API_TOKEN}"
    #|expect:
    #|  status: 200
    #|
  match @runner.build_url(resolved_of(source), @runner.new_context(), no_env) {
    Ok(url) => fail("expected a missing-variable error, got \{url}")
    Err(msg) =>
      @test.assert_eq(
        msg.contains("environment variable \"API_TOKEN\" is not set"),
        true,
      )
  }
}

// ---------------------------------------------------------------------------
// Placeholder expansion
// ---------------------------------------------------------------------------

///|
test "resolve_placeholders substitutes a bound variable" {
  let context = @runner.new_context()
  context["token"] = "abc"
  @test.assert_eq(
    ok_of(@runner.resolve_placeholders("Bearer {{token}}", context, no_env)),
    "Bearer abc",
  )
}

///|
test "resolve_placeholders trims the name inside a variable reference" {
  let context = @runner.new_context()
  context["token"] = "abc"
  @test.assert_eq(
    ok_of(@runner.resolve_placeholders("{{ token }}", context, no_env)),
    "abc",
  )
}

///|
test "resolve_placeholders leaves an unbound variable visible" {
  @test.assert_eq(
    ok_of(
      @runner.resolve_placeholders("{{token}}", @runner.new_context(), no_env),
    ),
    "{{token}}",
  )
}

///|
test "resolve_placeholders reads a set environment variable" {
  @test.assert_eq(
    ok_of(
      @runner.resolve_placeholders(
        "tok=${API_TOKEN}",
        @runner.new_context(),
        env_with_api_token,
      ),
    ),
    "tok=s3cret",
  )
}

///|
test "resolve_placeholders falls back when the variable is unset" {
  @test.assert_eq(
    ok_of(
      @runner.resolve_placeholders(
        "tok=${API_TOKEN:-anonymous}",
        @runner.new_context(),
        no_env,
      ),
    ),
    "tok=anonymous",
  )
}

///|
test "resolve_placeholders prefers the environment over the fallback" {
  @test.assert_eq(
    ok_of(
      @runner.resolve_placeholders(
        "${API_TOKEN:-anonymous}",
        @runner.new_context(),
        env_with_api_token,
      ),
    ),
    "s3cret",
  )
}

///|
test "resolve_placeholders errors on an unset variable without a fallback" {
  let message = err_of(
    @runner.resolve_placeholders(
      "tok=${API_TOKEN}",
      @runner.new_context(),
      no_env,
    ),
  )
  @test.assert_eq(message.contains("API_TOKEN"), true)
  @test.assert_eq(message.contains("${API_TOKEN:-fallback}"), true)
}

///|
test "resolve_placeholders errors on an empty environment reference" {
  let message = err_of(
    @runner.resolve_placeholders("${}", @runner.new_context(), no_env),
  )
  @test.assert_eq(message.contains("empty environment reference"), true)
}

///|
test "resolve_placeholders errors on an unterminated variable reference" {
  let message = err_of(
    @runner.resolve_placeholders("{{token", @runner.new_context(), no_env),
  )
  @test.assert_eq(message.contains("unterminated variable reference"), true)
}

///|
test "resolve_placeholders errors on an unterminated environment reference" {
  let message = err_of(
    @runner.resolve_placeholders("${API_TOKEN", @runner.new_context(), no_env),
  )
  @test.assert_eq(message.contains("unterminated environment reference"), true)
}

///|
test "resolve_placeholders copies a substituted value verbatim" {
  // The scan is a single pass, so a value that itself looks like a placeholder
  // must survive as text: a token carrying `${...}` is data, not a template.
  let context = @runner.new_context()
  context["token"] = "${API_TOKEN}"
  @test.assert_eq(
    ok_of(
      @runner.resolve_placeholders("{{token}}", context, env_with_api_token),
    ),
    "${API_TOKEN}",
  )
}

///|
test "resolve_placeholders mixes both channels in one string" {
  let context = @runner.new_context()
  context["user"] = "wu"
  @test.assert_eq(
    ok_of(
      @runner.resolve_placeholders(
        "{{user}}:${API_TOKEN:-none}:{{missing}}", context, env_with_api_token,
      ),
    ),
    "wu:s3cret:{{missing}}",
  )
}

///|
test "resolve_placeholders returns plain text untouched" {
  @test.assert_eq(
    ok_of(
      @runner.resolve_placeholders(
        "https://a.test/users",
        @runner.new_context(),
        no_env,
      ),
    ),
    "https://a.test/users",
  )
}

// ---------------------------------------------------------------------------
// Config merging
// ---------------------------------------------------------------------------

///|
test "a suite without a config block parses into the empty config" {
  let source =
    #|name: "no config"
    #|request:
    #|  url: "https://a.test"
    #|expect:
    #|  status: 200
    #|
  @test.assert_eq(suite_of(source).config.is_empty(), true)
}

///|
test "resolve_request keeps an absolute url and ignores base_url" {
  let source =
    #|config:
    #|  base_url: "https://api.test/v1"
    #|name: "absolute"
    #|request:
    #|  url: "https://other.test/ping"
    #|expect:
    #|  status: 200
    #|
  @test.assert_eq(resolved_of(source).url, "https://other.test/ping")
}

///|
test "resolve_request joins a relative url onto base_url" {
  let source =
    #|config:
    #|  base_url: "https://api.test/v1/"
    #|name: "relative"
    #|request:
    #|  url: "/users"
    #|expect:
    #|  status: 200
    #|
  @test.assert_eq(resolved_of(source).url, "https://api.test/v1/users")
}

///|
test "resolve_request joins a relative url without a leading slash" {
  let source =
    #|config:
    #|  base_url: "https://api.test"
    #|name: "relative"
    #|request:
    #|  url: "users"
    #|expect:
    #|  status: 200
    #|
  @test.assert_eq(resolved_of(source).url, "https://api.test/users")
}

///|
test "resolve_request rejects a relative url with no base_url" {
  let source =
    #|name: "no base"
    #|request:
    #|  url: "/users"
    #|expect:
    #|  status: 200
    #|
  let suite = suite_of(source)
  match @runner.resolve_request(suite.cases[0].request, suite.config) {
    Ok(resolved) => fail("expected a base_url error, got \{resolved.url}")
    Err(msg) => @test.assert_eq(msg.contains("base_url"), true)
  }
}

///|
test "resolve_request merges global headers and lets a case override one" {
  let source =
    #|config:
    #|  base_url: "https://api.test"
    #|  global_headers:
    #|    Accept: "application/json"
    #|    X-Api-Version: "2024-01"
    #|name: "headers"
    #|request:
    #|  url: "/users"
    #|  headers:
    #|    x-api-version: "2025-06"
    #|    X-Trace: "abc"
    #|expect:
    #|  status: 200
    #|
  let headers = resolved_of(source).headers
  @test.assert_eq(headers.length(), 3)
  @test.assert_eq(headers[0].0, "Accept")
  @test.assert_eq(headers[0].1, "application/json")
  // The override replaces the global in place, so the global order survives.
  @test.assert_eq(headers[1].0, "x-api-version")
  @test.assert_eq(headers[1].1, "2025-06")
  @test.assert_eq(headers[2].0, "X-Trace")
}

///|
test "resolve_request keeps global headers when the case declares none" {
  let source =
    #|config:
    #|  base_url: "https://api.test"
    #|  global_headers:
    #|    Accept: "application/json"
    #|name: "inherits"
    #|request:
    #|  url: "/users"
    #|expect:
    #|  status: 200
    #|
  let headers = resolved_of(source).headers
  @test.assert_eq(headers.length(), 1)
  @test.assert_eq(headers[0].0, "Accept")
}

///|
test "resolve_request carries the query parameters of the case" {
  let source =
    #|config:
    #|  base_url: "https://api.test"
    #|name: "query"
    #|request:
    #|  url: "/search"
    #|  query:
    #|    q: "moon"
    #|expect:
    #|  status: 200
    #|
  let query = resolved_of(source).query
  @test.assert_eq(query.length(), 1)
  @test.assert_eq(query[0].0, "q")
  @test.assert_eq(query[0].1, "moon")
}

///|
test "resolve_request takes the case timeout over the global one" {
  let source =
    #|config:
    #|  base_url: "https://api.test"
    #|  global_timeout: 8000
    #|name: "case timeout"
    #|request:
    #|  url: "/slow"
    #|  timeout: 250
    #|expect:
    #|  status: 200
    #|
  @test.assert_eq(resolved_of(source).timeout_ms, 250)
}

///|
test "resolve_request takes the global timeout over the caller default" {
  let source =
    #|config:
    #|  base_url: "https://api.test"
    #|  global_timeout: 8000
    #|name: "global timeout"
    #|request:
    #|  url: "/slow"
    #|expect:
    #|  status: 200
    #|
  let suite = suite_of(source)
  let resolved = match
    @runner.resolve_request(
      suite.cases[0].request,
      suite.config,
      timeout_ms=1234,
    ) {
    Ok(r) => r
    Err(msg) => fail("request should resolve: \{msg}")
  }
  @test.assert_eq(resolved.timeout_ms, 8000)
}

///|
test "resolve_request falls back to the caller default with no timeout declared" {
  let source =
    #|name: "caller default"
    #|request:
    #|  url: "https://a.test"
    #|expect:
    #|  status: 200
    #|
  let suite = suite_of(source)
  let resolved = match
    @runner.resolve_request(
      suite.cases[0].request,
      suite.config,
      timeout_ms=1234,
    ) {
    Ok(r) => r
    Err(msg) => fail("request should resolve: \{msg}")
  }
  @test.assert_eq(resolved.timeout_ms, 1234)
}

///|
test "resolve_request keeps a placeholder inside base_url unresolved" {
  // Merging happens before expansion, so a base URL may itself be templated.
  let source =
    #|config:
    #|  base_url: "https://{{host}}/v1"
    #|name: "templated base"
    #|request:
    #|  url: "/users"
    #|expect:
    #|  status: 200
    #|
  let context = @runner.new_context()
  context["host"] = "api.test"
  @test.assert_eq(url_of(source, context, no_env), "https://api.test/v1/users")
}

// ---------------------------------------------------------------------------
// Response headers
// ---------------------------------------------------------------------------

///|
test "split_response_headers drops the status line and stops at the blank line" {
  let raw =
    #|HTTP/1.1 200 OK
    #|Content-Type: application/json
    #|X-Request-Id: abc
    #|
    #|{"ok":true}
  let (headers, body) = @runner.split_response_headers(raw)
  @test.assert_eq(headers.length(), 2)
  @test.assert_eq(headers[0].0, "Content-Type")
  @test.assert_eq(headers[0].1, "application/json")
  @test.assert_eq(headers[1].1, "abc")
  @test.assert_eq(body.trim(), "{\"ok\":true}")
}

///|
test "split_response_headers reads a CRLF reply the same way" {
  let (headers, body) = @runner.split_response_headers(
    "HTTP/1.1 204 No Content\r\nX-Empty: yes\r\n\r\n",
  )
  @test.assert_eq(headers.length(), 1)
  @test.assert_eq(headers[0].0, "X-Empty")
  @test.assert_eq(headers[0].1, "yes")
  @test.assert_eq(body, "")
}

///|
test "split_response_headers joins a folded continuation onto its header" {
  let (headers, body) = @runner.split_response_headers(
    "HTTP/1.1 200 OK\nX-Long: first\n  second\n\nbody",
  )
  @test.assert_eq(headers.length(), 1)
  @test.assert_eq(headers[0].1, "first second")
  @test.assert_eq(body, "body")
}

///|
test "split_response_headers keeps a body that itself carries blank lines" {
  let (headers, body) = @runner.split_response_headers(
    "HTTP/1.1 200 OK\nContent-Type: text/plain\n\nline one\n\nline two",
  )
  @test.assert_eq(headers.length(), 1)
  @test.assert_eq(body, "line one\n\nline two")
}

///|
test "find_header folds case and returns the first match" {
  let headers : Array[(String, String)] = [
    ("Content-Type", "application/json"),
    ("X-Request-Id", "abc"),
  ]
  @test.assert_eq(
    @runner.find_header(headers, "content-type"),
    Some("application/json"),
  )
  @test.assert_eq(@runner.find_header(headers, "X-REQUEST-ID"), Some("abc"))
  @test.assert_eq(@runner.find_header(headers, "X-Missing"), None)
}

///|
test "find_cookie reads the pair that opens a Set-Cookie header" {
  let headers : Array[(String, String)] = [
    ("Content-Type", "application/json"),
    ("Set-Cookie", "session=abc123; Path=/; HttpOnly"),
    ("Set-Cookie", "theme=dark"),
  ]
  @test.assert_eq(@runner.find_cookie(headers, "session"), Some("abc123"))
  @test.assert_eq(@runner.find_cookie(headers, "theme"), Some("dark"))
  // Cookie names are case-sensitive, unlike header names.
  @test.assert_eq(@runner.find_cookie(headers, "Session"), None)
  @test.assert_eq(@runner.find_cookie(headers, "token"), None)
}

// ---------------------------------------------------------------------------
// `set:` extraction
// ---------------------------------------------------------------------------

///|
/// The first `set:` directive a fixture declares.
fn set_of(source : String) -> @parser.SetSpec raise {
  return suite_of(source).cases[0].expect.sets[0]
}

///|
test "extract_value reads a body path by default" {
  let spec =
    #|name: "from body"
    #|request:
    #|  url: "https://a.test"
    #|expect:
    #|  status: 200
    #|  set: id = data.id
    #|
  @test.assert_eq(
    ok_of(@runner.extract_value(set_of(spec), [], "{\"data\":{\"id\":7}}")),
    "7",
  )
}

///|
test "extract_value reads a response header named by the directive" {
  let source =
    #|name: "from header"
    #|request:
    #|  url: "https://a.test"
    #|expect:
    #|  status: 200
    #|  set: token = header.X-Token
    #|
  let spec = set_of(source)
  @test.assert_eq(
    ok_of(@runner.extract_value(spec, [("x-token", "abc")], "")),
    "abc",
  )
  let missing = err_of(@runner.extract_value(spec, [], ""))
  @test.assert_eq(missing.contains("header \"X-Token\" is missing"), true)
}

///|
test "extract_value reads a cookie named by the directive" {
  let source =
    #|name: "from cookie"
    #|request:
    #|  url: "https://a.test"
    #|expect:
    #|  status: 200
    #|  set: sid = cookie.session
    #|
  let spec = set_of(source)
  @test.assert_eq(
    ok_of(
      @runner.extract_value(spec, [("Set-Cookie", "session=xyz; Path=/")], ""),
    ),
    "xyz",
  )
  let missing = err_of(@runner.extract_value(spec, [], ""))
  @test.assert_eq(missing.contains("cookie \"session\" was not set"), true)
}

///|
/// The non-`js` backends have no transport at all, so the runner must report
/// that instead of producing a fake response. The `js` counterpart of this
/// test lives in `runner_http_test.mbt`.
#cfg(not(target="js"))
test "run_request reports the missing transport on non-js backends" {
  let source =
    #|name: "transport"
    #|request:
    #|  url: "https://a.test"
    #|expect:
    #|  status: 200
    #|
  let suite = suite_of(source)
  match
    @runner.run_request(
      suite.cases[0].request,
      suite.config,
      @runner.new_context(),
    ) {
    Err(_) => ()
    Ok(response) => fail("expected no transport, got status \{response.status}")
  }
}
