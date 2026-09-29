/// MoonProbe - runner tests
///
/// Covers the pure decision logic of the runner — URL building and request
/// resolution — so these run on every backend. The transport itself is
/// exercised separately in `runner_http_test.mbt`, which is `js`-only.

/// Parse `.probe` source and return the request of its first case.
fn request_of(source : String) -> @parser.Request raise {
  match @parser.parse(source) {
    Ok(suite) => suite.cases[0].request
    Err(msg) => fail("fixture should parse: \{msg}")
  }
}

test "build_url leaves a url without query parameters untouched" {
  let source =
    #|name: "no query"
    #|request:
    #|  url: "https://a.test/users"
    #|expect:
    #|  status: 200
    #|
  let request = request_of(source)
  @test.assert_eq(
    @runner.build_url(request, @runner.new_context()),
    "https://a.test/users",
  )
}

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
  let request = request_of(source)
  @test.assert_eq(
    @runner.build_url(request, @runner.new_context()),
    "https://a.test/search?q=a%20b%2Bc&page=1",
  )
}

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
  let request = request_of(source)
  @test.assert_eq(
    @runner.build_url(request, @runner.new_context()),
    "https://a.test/search?via=cli&page=2",
  )
}

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
  let request = request_of(source)
  let context = @runner.new_context()
  context["id"] = "42"
  context["token"] = "abc def"
  @test.assert_eq(
    @runner.build_url(request, context),
    "https://a.test/users/42/profile?token=abc%20def",
  )
}

test "build_url leaves an unbound placeholder verbatim" {
  let source =
    #|name: "unbound"
    #|request:
    #|  url: "https://a.test/{{missing}}"
    #|expect:
    #|  status: 200
    #|
  let request = request_of(source)
  @test.assert_eq(
    @runner.build_url(request, @runner.new_context()),
    "https://a.test/{{missing}}",
  )
}

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
  let request = request_of(source)
  match @runner.run_request(request, @runner.new_context()) {
    Err(_) => ()
    Ok(response) => fail("expected no transport, got status \{response.status}")
  }
}