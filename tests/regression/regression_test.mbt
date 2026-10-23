/// MoonProbe - acceptance regression suite
///
/// One test per failure of the September acceptance review. These are not unit
/// tests: each one starts from a `.probe` source, lets the runner resolve and
/// render the request, answers with raw HTTP/1.1 bytes, runs them through the
/// response parser and the assertion engine, and looks only at what the CLI
/// would report. A change that breaks a user-visible guarantee breaks a test
/// here, whatever package it was made in.
///
/// The five cases are:
///
///   1. a JSON number `7` never satisfies an expectation of `999`,
///   2. the client starts on macOS / Linux without an external executable,
///   3. a `100 Continue` header block never leaks into the body,
///   4. a URL fragment is kept in the value and never sent as a query,
///   5. a body that starts with `@` is sent as bytes, not read from a file.

///|
/// Encode text the way `render_request` does, so a fixture body is byte-exact.
fn regression_utf8(text : String) -> Bytes {
  return @utf8.encode(text)
}

///|
/// A transport that replays one canned HTTP/1.1 reply through the real protocol
/// stack and records every request the client rendered.
fn regression_transport(
  reply : String,
  wires : Array[String],
) -> @runner.Transport {
  return fn(
    verb : String,
    url : String,
    headers : String,
    body : String,
    _timeout_ms : Int32,
  ) -> Result[(Int32, Array[(String, String)], String), String] {
    let payload = if body.length() == 0 { None } else { Some(body) }
    let exchange = fn(wire : String) -> Result[Bytes, String] {
      wires.push(wire)
      Ok(regression_utf8(reply))
    }
    match @http.send_with(exchange, verb, url, headers, payload) {
      Ok(response) => Ok((response.status, response.headers, response.body))
      Err(msg) => Err(msg)
    }
  }
}

///|
/// Parse a suite source, run it against `reply`, and hand back the results with
/// the requests the client rendered.
fn regression_run(
  source : String,
  reply : String,
) -> (Array[@runner.TestResult], Array[String]) raise {
  let suite = match @parser.parse(source) {
    Ok(value) => value
    Err(msg) => fail("the fixture should parse: \{msg}")
  }
  let wires : Array[String] = []
  let results = match
    @runner.run_suite_with(regression_transport(reply, wires), suite) {
    Ok(value) => value
    Err(msg) => fail("the suite should run: \{msg}")
  }
  return (results, wires)
}

///|
/// Fire a request at a closed local port and return the error it produces.
///
/// A backend with no socket says so; the `js` backend reaches the socket and is
/// refused. Both paths must answer with a message -- never raise, and never
/// depend on finding a tool.
fn regression_platform_error() -> String raise {
  match @http.send_platform("GET", "http://127.0.0.1:1/", "", None, 1000) {
    Ok(_) => fail("a closed port must not be reported as a successful request")
    Err(msg) => msg
  }
}

// ---------------------------------------------------------------------------
// 1. JSON numbers compare by value and by type
// ---------------------------------------------------------------------------

///|
test "regression: a json 7 never satisfies an expectation of 999" {
  let source =
    #|name: "numeric regression"
    #|request:
    #|  url: "http://api.test/v1/code"
    #|expect:
    #|  status: 200
    #|  json:
    #|    code: 999
    #|
  let mismatch = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 10\r\n\r\n{\"code\":7}"
  let (failed, _) = regression_run(source, mismatch)
  @test.assert_eq(failed.length(), 1)
  @test.assert_eq(failed[0].passed(), false)
  @test.assert_eq(failed[0].failures.length(), 1)
  @test.assert_eq(
    failed[0].failures[0],
    "json: \"code\": expected Int 999, got Int 7",
  )

  // The same pipeline must accept the value that really is 999, so the failure
  // above is the comparison and not a broken fixture.
  let match_reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n{\"code\":999}"
  let (passed, _) = regression_run(source, match_reply)
  @test.assert_eq(passed[0].passed(), true)
}

// ---------------------------------------------------------------------------
// 2. The client starts without an external executable
// ---------------------------------------------------------------------------

///|
test "regression: the http client starts without a platform-specific executable" {
  // Rendering is pure: the first thing a run does on macOS or Linux is produce
  // bytes, not look for `curl.exe`. A localhost request is all this needs.
  let url = match @http.parse_url("http://localhost:8080/health?probe=1") {
    Ok(value) => value
    Err(msg) => fail("the url should parse: \{msg}")
  }
  let wire = @http.render_request("GET", url, "", None)
  @test.assert_eq(wire.has_prefix("GET /health?probe=1 HTTP/1.1\r\n"), true)
  @test.assert_eq(wire.contains("Host: localhost:8080\r\n"), true)

  // And when no socket is reachable, the transport reports it. The message names
  // the backend, never a missing binary.
  let message = regression_platform_error()
  @test.assert_eq(message.contains("curl"), false)
  @test.assert_eq(message.length() > 0, true)
}

// ---------------------------------------------------------------------------
// 3. POST 100 Continue
// ---------------------------------------------------------------------------

///|
test "regression: a 100 continue header block never reaches the body" {
  let wires : Array[String] = []
  let exchange = fn(wire : String) -> Result[Bytes, String] {
    wires.push(wire)
    Ok(
      regression_utf8(
        "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Type: text/plain\r\nContent-Length: 7\r\n\r\ncreated",
      ),
    )
  }
  let response = match
    @http.send_with(
      exchange,
      "POST",
      "http://api.test/upload",
      "",
      Some("@payload"),
    ) {
    Ok(value) => value
    Err(msg) => fail("the exchange should succeed: \{msg}")
  }
  @test.assert_eq(response.status, 201)
  @test.assert_eq(response.interim, 1)
  @test.assert_eq(response.body, "created")
  @test.assert_eq(wires.length(), 1)
  @test.assert_eq(wires[0].has_suffix("\r\n\r\n@payload"), true)
  @test.assert_eq(wires[0].contains("Content-Length: 8\r\n"), true)
}

// ---------------------------------------------------------------------------
// 4. URL fragments
// ---------------------------------------------------------------------------

///|
test "regression: a url fragment is kept and never sent as a query" {
  let url = match @http.parse_url("http://api.test/items?page=2#top") {
    Ok(value) => value
    Err(msg) => fail("the url should parse: \{msg}")
  }
  @test.assert_eq(url.query, Some("page=2"))
  @test.assert_eq(url.fragment, Some("top"))
  let wire = @http.render_request("GET", url, "", None)
  @test.assert_eq(wire.has_prefix("GET /items?page=2 HTTP/1.1\r\n"), true)
  @test.assert_eq(wire.contains("#top"), false)

  // A fragment that looks like a query must stay a fragment: the old transport
  // let this text reach the query string.
  let tricky = match @http.parse_url("http://api.test/items#section?page=9") {
    Ok(value) => value
    Err(msg) => fail("the url should parse: \{msg}")
  }
  @test.assert_eq(tricky.query, None)
  @test.assert_eq(tricky.fragment, Some("section?page=9"))
  @test.assert_eq(
    @http.render_request("GET", tricky, "", None).has_prefix(
      "GET /items HTTP/1.1\r\n",
    ),
    true,
  )
}

// ---------------------------------------------------------------------------
// 5. A body that starts with `@`
// ---------------------------------------------------------------------------

///|
test "regression: an at-sign body is sent as bytes, not read as a file" {
  let source =
    #|name: "at sign body"
    #|request:
    #|  method: POST
    #|  url: "http://api.test/hooks"
    #|  body: "@deploy.json"
    #|expect:
    #|  status: 200
    #|  json:
    #|    ok: true
    #|
  let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}"
  let (results, wires) = regression_run(source, reply)
  @test.assert_eq(results.length(), 1)
  @test.assert_eq(results[0].passed(), true)
  @test.assert_eq(wires.length(), 1)
  @test.assert_eq(wires[0].contains("Content-Length: 12\r\n"), true)
  @test.assert_eq(wires[0].has_suffix("\r\n\r\n@deploy.json"), true)
}
