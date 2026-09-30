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

// ---------------------------------------------------------------------------
// Environment variables: boundary values
// ---------------------------------------------------------------------------

///|
/// An environment where `EMPTY_VAR` is exported but carries nothing, which is
/// how a CI job exposes an optional secret that was left unfilled.
fn empty_env(key : String) -> String? {
  if key == "EMPTY_VAR" {
    return Some("")
  }
  return None
}

///|
test "resolve_placeholders substitutes a variable set to the empty string" {
  @test.assert_eq(
    ok_of(
      @runner.resolve_placeholders(
        "tok=${EMPTY_VAR}",
        @runner.new_context(),
        empty_env,
      ),
    ),
    "tok=",
  )
}

///|
test "resolve_placeholders keeps an empty value instead of the fallback" {
  // "set but empty" and "not set" are different states: a variable that exists
  // is honoured even when it carries nothing, so the fallback is not used.
  @test.assert_eq(
    ok_of(
      @runner.resolve_placeholders(
        "tok=${EMPTY_VAR:-anonymous}",
        @runner.new_context(),
        empty_env,
      ),
    ),
    "tok=",
  )
}

///|
test "resolve_placeholders accepts an empty fallback" {
  @test.assert_eq(
    ok_of(
      @runner.resolve_placeholders(
        "tok=${API_TOKEN:-}",
        @runner.new_context(),
        no_env,
      ),
    ),
    "tok=",
  )
}

///|
test "resolve_placeholders splits the fallback at the first separator" {
  // The separator is the first `:-`, so whatever follows it is the fallback —
  // including a second `:-` that is part of the default text.
  @test.assert_eq(
    ok_of(
      @runner.resolve_placeholders(
        "${API_TOKEN:-a:-b}",
        @runner.new_context(),
        no_env,
      ),
    ),
    "a:-b",
  )
}

///|
test "resolve_placeholders keeps a fallback verbatim" {
  @test.assert_eq(
    ok_of(
      @runner.resolve_placeholders(
        "${API_TOKEN:-/usr/local/bin}",
        @runner.new_context(),
        no_env,
      ),
    ),
    "/usr/local/bin",
  )
}

///|
test "resolve_placeholders trims the name of an environment reference" {
  @test.assert_eq(
    ok_of(
      @runner.resolve_placeholders(
        "${ API_TOKEN }",
        @runner.new_context(),
        env_with_api_token,
      ),
    ),
    "s3cret",
  )
}

///|
test "resolve_placeholders errors on a fallback with no variable name" {
  let message = err_of(
    @runner.resolve_placeholders("${:-fallback}", @runner.new_context(), no_env),
  )
  @test.assert_eq(message.contains("empty environment reference"), true)
}

///|
test "resolve_placeholders substitutes a variable bound to the empty string" {
  let context = @runner.new_context()
  context["empty"] = ""
  @test.assert_eq(
    ok_of(@runner.resolve_placeholders("[{{empty}}]", context, no_env)),
    "[]",
  )
}

///|
test "resolve_placeholders handles two adjacent references" {
  let context = @runner.new_context()
  context["a"] = "1"
  context["b"] = "2"
  @test.assert_eq(
    ok_of(@runner.resolve_placeholders("{{a}}{{b}}", context, no_env)),
    "12",
  )
}

///|
test "build_url injects an empty environment variable into the url" {
  let source =
    #|name: "empty env"
    #|request:
    #|  url: "https://a.test/users?token=${EMPTY_VAR}"
    #|expect:
    #|  status: 200
    #|
  @test.assert_eq(
    url_of(source, @runner.new_context(), empty_env),
    "https://a.test/users?token=",
  )
}

///|
test "resolve_request treats a non-http scheme as relative and demands a base_url" {
  // Only `http://` and `https://` make a URL absolute, so anything else is
  // rejected with the same actionable message a relative URL gets.
  let source =
    #|name: "weird scheme"
    #|request:
    #|  url: "ftp://files.test/x"
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
test "a config block that declares only a retry budget is not empty" {
  let source =
    #|config:
    #|  retry: 3
    #|name: "retry only"
    #|request:
    #|  url: "https://a.test"
    #|expect:
    #|  status: 200
    #|
  @test.assert_eq(suite_of(source).config.is_empty(), false)
  @test.assert_eq(suite_of(source).config.retry_count, Some(3))
}

// ---------------------------------------------------------------------------
// Retrying
// ---------------------------------------------------------------------------

///|
/// The reply a scripted transport hands back: a response, or the message of a
/// request that never reached the server.
type Reply = Result[(Int, Array[(String, String)], String), String]

///|
/// A transport that answers with a scripted list of replies and remembers what
/// it was asked to send.
///
/// The retry rules are decided by the runner alone, so handing it a transport
/// that never touches the network pins them down exactly: a 500 followed by a
/// 200 is the smallest possible proof that a retry happened.
struct Script {
  replies : Array[Reply]
  /// One `"VERB url | headers"` entry per call, in order.
  calls : Array[String]
  mut index : Int
}

///|
/// A script that will answer its `n`-th call with its `n`-th reply.
fn script(replies : Array[Reply]) -> Script {
  return { replies, calls: [], index: 0, }
}

///|
/// A successful reply with the given status and body.
fn reply(status : Int, body : String) -> Reply {
  return Ok((status, [], body))
}

///|
/// A successful reply that also carries the given headers.
fn reply_with(
  status : Int,
  headers : Array[(String, String)],
  body : String,
) -> Reply {
  return Ok((status, headers, body))
}

///|
/// A request that never reached the server.
fn refused(message : String) -> Reply {
  return Err(message)
}

///|
/// The transport of a script: one scripted reply per call, in order.
fn Script::transport(self : Script) -> @runner.Transport {
  fn(
    verb : String,
    url : String,
    headers : String,
    _body : String,
    _timeout_ms : Int,
  ) -> Result[(Int, Array[(String, String)], String), String] {
    self.calls.push("\{verb} \{url} | \{headers}")
    let i = self.index
    self.index = i + 1
    if i < self.replies.length() {
      return self.replies[i]
    }
    return Err(
      "the script holds \{self.replies.length()} replies but was asked for \{i + 1}",
    )
  }
}

///|
/// The first case of `source`, sent through `script` with the given budget.
fn send_of(
  source : String,
  script : Script,
  retry_count : Int,
) -> Result[@runner.Response, String] raise {
  let suite = suite_of(source)
  return @runner.run_request_with(
    script.transport(),
    suite.cases[0].request,
    suite.config,
    @runner.new_context(),
    retry_count~,
  )
}

///|
/// Unwrap a sent response, failing the test on a transport error.
fn ok_response(
  result : Result[@runner.Response, String],
) -> @runner.Response raise {
  match result {
    Ok(response) => response
    Err(msg) => fail("expected a response, got an error: \{msg}")
  }
}

///|
/// The message of a failed request, failing the test on a response.
fn response_error(result : Result[@runner.Response, String]) -> String raise {
  match result {
    Ok(response) => fail("expected a transport error, got \{response.status}")
    Err(msg) => msg
  }
}

///|
/// A plain case at an absolute URL, used by the retry and timing tests.
const FX_PING : String =
  #|name: "ping"
  #|request:
  #|  url: "https://a.test/ping"
  #|expect:
  #|  status: 200
  #|

///|
test "is_retriable_status covers the server-error range only" {
  @test.assert_eq(@runner.is_retriable_status(0), false)
  @test.assert_eq(@runner.is_retriable_status(200), false)
  @test.assert_eq(@runner.is_retriable_status(404), false)
  @test.assert_eq(@runner.is_retriable_status(499), false)
  @test.assert_eq(@runner.is_retriable_status(500), true)
  @test.assert_eq(@runner.is_retriable_status(503), true)
  @test.assert_eq(@runner.is_retriable_status(599), true)
  @test.assert_eq(@runner.is_retriable_status(600), false)
}

///|
test "send_with_retry returns the last attempt once the budget is spent" {
  let script = script([reply(503, "busy"), reply(500, "still busy")])
  let response = ok_response(send_of(FX_PING, script, 1))
  // A budget is a limit, not a promise: the second 5xx is reported as it is.
  @test.assert_eq(response.status, 500)
  @test.assert_eq(response.attempts, 2)
  @test.assert_eq(script.calls.length(), 2)
}

///|
test "send_with_retry returns the attempt that succeeds" {
  let script = script([reply(500, "oops"), reply(200, "{\"ok\":true}")])
  let response = ok_response(send_of(FX_PING, script, 1))
  @test.assert_eq(response.status, 200)
  @test.assert_eq(response.body, "{\"ok\":true}")
  @test.assert_eq(response.attempts, 2)
  @test.assert_eq(script.calls.length(), 2)
}

///|
test "send_with_retry does not retry a 4xx" {
  let script = script([reply(404, "gone"), reply(200, "unused")])
  let response = ok_response(send_of(FX_PING, script, 3))
  // A wrong request stays wrong however many times it is sent, so the second
  // reply is never consumed even though the budget allows it.
  @test.assert_eq(response.status, 404)
  @test.assert_eq(response.attempts, 1)
  @test.assert_eq(script.calls.length(), 1)
  @test.assert_eq(script.index, 1)
}

///|
test "send_with_retry retries a transport failure and then reports it" {
  let script = script([
    refused("connection refused"),
    refused("connection refused"),
  ])
  let message = response_error(send_of(FX_PING, script, 1))
  @test.assert_eq(message, "connection refused")
  @test.assert_eq(script.calls.length(), 2)
}

///|
test "send_with_retry accepts a transport that recovers on the retry" {
  let script = script([refused("timed out"), reply(200, "back")])
  let response = ok_response(send_of(FX_PING, script, 1))
  @test.assert_eq(response.status, 200)
  @test.assert_eq(response.body, "back")
  @test.assert_eq(response.attempts, 2)
}

///|
test "send_with_retry sends once when the budget is zero" {
  let script = script([reply(500, "busy")])
  let response = ok_response(send_of(FX_PING, script, 0))
  @test.assert_eq(response.status, 500)
  @test.assert_eq(response.attempts, 1)
  @test.assert_eq(script.calls.length(), 1)
}

///|
test "send_with_retry reads a negative budget as no retries" {
  let script = script([reply(500, "busy")])
  let response = ok_response(send_of(FX_PING, script, -1))
  @test.assert_eq(response.attempts, 1)
  @test.assert_eq(script.calls.length(), 1)
}

///|
test "send_with_retry stamps the call it returned" {
  let script = script([reply(500, "busy"), reply(200, "fine")])
  let before = @env.now()
  let response = ok_response(send_of(FX_PING, script, 1))
  let after = @env.now()
  // The two readings bracket the call itself, so they must fall inside the
  // window this test measured — and `elapsed_ms` is their difference, which is
  // the transport's own latency rather than the time the retry sequence took.
  @test.assert_eq(response.attempts, 2)
  @test.assert_eq(response.started_at_ms >= before, true)
  @test.assert_eq(response.finished_at_ms <= after, true)
  @test.assert_eq(response.finished_at_ms >= response.started_at_ms, true)
  @test.assert_eq(
    response.elapsed_ms(),
    response.finished_at_ms - response.started_at_ms,
  )
}

///|
test "resolve_request takes the case retry budget over the global one" {
  let source =
    #|config:
    #|  retry: 3
    #|name: "case budget"
    #|request:
    #|  url: "https://a.test/ping"
    #|  retry: 0
    #|expect:
    #|  status: 200
    #|
  @test.assert_eq(resolved_of(source).retry_count, 0)
}

///|
test "resolve_request takes the global retry budget over the caller default" {
  let source =
    #|config:
    #|  retry: 4
    #|name: "global budget"
    #|request:
    #|  url: "https://a.test/ping"
    #|expect:
    #|  status: 200
    #|
  let suite = suite_of(source)
  let resolved = match
    @runner.resolve_request(suite.cases[0].request, suite.config, retry_count=9) {
    Ok(r) => r
    Err(msg) => fail("request should resolve: \{msg}")
  }
  @test.assert_eq(resolved.retry_count, 4)
}

///|
test "resolve_request falls back to the caller retry budget" {
  let source =
    #|name: "caller budget"
    #|request:
    #|  url: "https://a.test/ping"
    #|expect:
    #|  status: 200
    #|
  let suite = suite_of(source)
  let resolved = match
    @runner.resolve_request(suite.cases[0].request, suite.config, retry_count=7) {
    Ok(r) => r
    Err(msg) => fail("request should resolve: \{msg}")
  }
  @test.assert_eq(resolved.retry_count, 7)
}

///|
test "resolve_request defaults the retry budget to one" {
  let source =
    #|name: "default budget"
    #|request:
    #|  url: "https://a.test/ping"
    #|expect:
    #|  status: 200
    #|
  @test.assert_eq(resolved_of(source).retry_count, @runner.DEFAULT_RETRY_COUNT)
}

// ---------------------------------------------------------------------------
// before_each / after_each
// ---------------------------------------------------------------------------

///|
/// Run a whole `.probe` source through `script`, hooks included.
fn run_source(
  source : String,
  script : Script,
) -> Array[@runner.TestResult] raise {
  let suite = suite_of(source)
  match @runner.run_suite_with(script.transport(), suite) {
    Ok(results) => results
    Err(msg) => fail("suite should run: \{msg}")
  }
}

///|
/// Whether the `n`-th recorded call was made to `path`.
fn called(script : Script, n : Int, path : String) -> Bool {
  return n < script.calls.length() && script.calls[n].contains(path)
}

///|
test "the hooks around a case run in nesting order" {
  let source =
    #|before_each:
    #|  name: "suite setup"
    #|  request:
    #|    url: "https://a.test/suite-setup"
    #|  expect:
    #|    status: 200
    #|after_each:
    #|  name: "suite teardown"
    #|  request:
    #|    url: "https://a.test/suite-teardown"
    #|  expect:
    #|    status: 200
    #|name: "the case"
    #|before_each:
    #|  name: "case setup"
    #|  request:
    #|    url: "https://a.test/case-setup"
    #|  expect:
    #|    status: 200
    #|after_each:
    #|  name: "case teardown"
    #|  request:
    #|    url: "https://a.test/case-teardown"
    #|  expect:
    #|    status: 200
    #|request:
    #|  url: "https://a.test/work"
    #|expect:
    #|  status: 200
    #|
  let script = script([
    reply(200, "ok"),
    reply(200, "ok"),
    reply(200, "ok"),
    reply(200, "ok"),
    reply(200, "ok"),
  ])
  let results = run_source(source, script)
  @test.assert_eq(results.length(), 1)
  @test.assert_eq(results[0].passed(), true)
  @test.assert_eq(script.calls.length(), 5)
  @test.assert_eq(called(script, 0, "/suite-setup"), true)
  @test.assert_eq(called(script, 1, "/case-setup"), true)
  @test.assert_eq(called(script, 2, "/work"), true)
  @test.assert_eq(called(script, 3, "/case-teardown"), true)
  @test.assert_eq(called(script, 4, "/suite-teardown"), true)
}

///|
test "suite hooks surround every case of the suite" {
  let source =
    #|before_each:
    #|  name: "setup"
    #|  request:
    #|    url: "https://a.test/setup"
    #|  expect:
    #|    status: 200
    #|after_each:
    #|  name: "teardown"
    #|  request:
    #|    url: "https://a.test/teardown"
    #|  expect:
    #|    status: 200
    #|name: "first"
    #|request:
    #|  url: "https://a.test/one"
    #|expect:
    #|  status: 200
    #|name: "second"
    #|request:
    #|  url: "https://a.test/two"
    #|expect:
    #|  status: 200
    #|
  let script = script([
    reply(200, "ok"),
    reply(200, "ok"),
    reply(200, "ok"),
    reply(200, "ok"),
    reply(200, "ok"),
    reply(200, "ok"),
  ])
  let results = run_source(source, script)
  @test.assert_eq(results.length(), 2)
  @test.assert_eq(results[0].passed(), true)
  @test.assert_eq(results[1].passed(), true)
  @test.assert_eq(script.calls.length(), 6)
  @test.assert_eq(called(script, 0, "/setup"), true)
  @test.assert_eq(called(script, 1, "/one"), true)
  @test.assert_eq(called(script, 2, "/teardown"), true)
  @test.assert_eq(called(script, 3, "/setup"), true)
  @test.assert_eq(called(script, 4, "/two"), true)
  @test.assert_eq(called(script, 5, "/teardown"), true)
}

///|
test "a failing before_each blocks the case body and names itself" {
  let source =
    #|before_each:
    #|  name: "suite setup"
    #|  request:
    #|    url: "https://a.test/suite-setup"
    #|  expect:
    #|    status: 200
    #|name: "the case"
    #|request:
    #|  url: "https://a.test/work"
    #|expect:
    #|  status: 200
    #|
  // The setup step asks for a 200 and the server answers 404, so the fixture it
  // was meant to prepare does not exist and sending the body would only bury
  // the real cause under a second failure.
  let script = script([reply(404, "no session")])
  let results = run_source(source, script)
  @test.assert_eq(results.length(), 1)
  @test.assert_eq(results[0].passed(), false)
  @test.assert_eq(results[0].failures.length(), 1)
  @test.assert_eq(
    results[0].failures[0].contains("before_each \"suite setup\""),
    true,
  )
  match results[0].response {
    None => ()
    Some(response) => fail("the body must not be sent, got \{response.status}")
  }
  @test.assert_eq(script.calls.length(), 1)
  @test.assert_eq(results[0].elapsed_ms, 0UL)
}

///|
test "a failing case-level before_each stops the remaining setup steps" {
  let source =
    #|name: "the case"
    #|before_each:
    #|  name: "first step"
    #|  request:
    #|    url: "https://a.test/setup-1"
    #|  expect:
    #|    status: 200
    #|  name: "second step"
    #|  request:
    #|    url: "https://a.test/setup-2"
    #|  expect:
    #|    status: 200
    #|request:
    #|  url: "https://a.test/work"
    #|expect:
    #|  status: 200
    #|
  // A later setup step usually depends on an earlier one, so the first failure
  // ends the setup phase instead of piling on follow-up errors.
  let script = script([reply(404, "gone")])
  let results = run_source(source, script)
  @test.assert_eq(results[0].passed(), false)
  @test.assert_eq(results[0].failures.length(), 1)
  @test.assert_eq(script.calls.length(), 1)
  @test.assert_eq(called(script, 0, "/setup-1"), true)
}

///|
test "a failing after_each is reported without hiding the case result" {
  let source =
    #|after_each:
    #|  name: "suite teardown"
    #|  request:
    #|    url: "https://a.test/suite-teardown"
    #|  expect:
    #|    status: 200
    #|name: "the case"
    #|request:
    #|  url: "https://a.test/work"
    #|expect:
    #|  status: 200
    #|
  let script = script([reply(200, "ok"), reply(404, "already gone")])
  let results = run_source(source, script)
  // Cleanup runs on every path, so a teardown that fails is still reported —
  // and the response of the case itself survives it.
  @test.assert_eq(results[0].passed(), false)
  @test.assert_eq(results[0].failures.length(), 1)
  @test.assert_eq(
    results[0].failures[0].contains("after_each \"suite teardown\""),
    true,
  )
  @test.assert_eq(results[0].response.unwrap().status, 200)
  @test.assert_eq(script.calls.length(), 2)
}

///|
test "a before_each step binds a variable the case then sends" {
  let source =
    #|before_each:
    #|  name: "sign in"
    #|  request:
    #|    method: POST
    #|    url: "https://a.test/login"
    #|  expect:
    #|    status: 200
    #|    set: token = header.X-Token
    #|name: "who am i"
    #|request:
    #|  url: "https://a.test/me"
    #|  headers:
    #|    Authorization: "Bearer {{token}}"
    #|expect:
    #|  status: 200
    #|
  let script = script([
    reply_with(200, [("X-Token", "tok-42")], ""),
    reply(200, "{}"),
  ])
  let results = run_source(source, script)
  @test.assert_eq(results[0].passed(), true)
  // The second call carries what the first one extracted: the setup step is
  // what makes the case it prepares reachable.
  @test.assert_eq(script.calls.length(), 2)
  @test.assert_eq(
    script.calls[1].contains("Authorization: Bearer tok-42"),
    true,
  )
}

///|
test "a hook that cannot be sent is reported as one more failure" {
  let source =
    #|before_each:
    #|  name: "suite setup"
    #|  request:
    #|    url: "https://a.test/suite-setup"
    #|  expect:
    #|    status: 200
    #|name: "the case"
    #|request:
    #|  url: "https://a.test/work"
    #|expect:
    #|  status: 200
    #|
  // The refused connection is retried like any other transport failure, so the
  // script must be able to answer twice before the message surfaces.
  let script = script([
    refused("connection refused"),
    refused("connection refused"),
  ])
  let results = run_source(source, script)
  // A hook never aborts the run: an unreachable setup step is one line of
  // explanation, and the remaining cases — and the report — stay alive.
  @test.assert_eq(results.length(), 1)
  @test.assert_eq(
    results[0].failures[0].contains(
      "before_each \"suite setup\": connection refused",
    ),
    true,
  )
}
