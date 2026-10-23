/// MoonProbe - http request tests
///
/// The request side is where three of the old transport's bugs can be pinned
/// down without a server:
///
///   - a fragment never reaches the request line,
///   - a body that begins with `@` is sent as bytes, not read as a file,
///   - the framing headers are computed from the body, never copied from the
///     header block.
///
/// `send_with` is driven with a fake exchange, so request rendering and response
/// parsing are exercised as one path, exactly as the runner uses them.

///|
/// The wire text of a GET with no headers and no body.
const FX_WIRE_GET : String = "GET /x HTTP/1.1\r\nHost: a.test\r\nUser-Agent: moonprobe/0.2.0\r\nAccept: */*\r\nConnection: close\r\n\r\n"

///|
test "render a GET with the default headers" {
  let url = match @http.parse_url("http://a.test/x") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  @test.assert_eq(@http.render_request("get", url, "", None), FX_WIRE_GET)
}

///|
test "render keeps the query and drops the fragment" {
  let url = match @http.parse_url("http://a.test/x?page=2#top") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  let wire = @http.render_request("GET", url, "", None)
  @test.assert_eq(wire.has_prefix("GET /x?page=2 HTTP/1.1\r\n"), true)
  @test.assert_eq(wire.contains("#top"), false)
}

///|
test "render a POST body that starts with an at sign" {
  // `curl --data-binary @file` reads a file; a body beginning with `@` must
  // therefore be sent literally instead of being reinterpreted.
  let url = match @http.parse_url("http://a.test/submit") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  let wire = @http.render_request("post", url, "", Some("@handle"))
  @test.assert_eq(
    wire, "POST /submit HTTP/1.1\r\nHost: a.test\r\nUser-Agent: moonprobe/0.2.0\r\nAccept: */*\r\nConnection: close\r\nContent-Length: 7\r\n\r\n@handle",
  )
}

///|
test "content-length counts utf-8 bytes" {
  let url = match @http.parse_url("http://a.test/submit") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  let wire = @http.render_request("POST", url, "", Some("操作"))
  @test.assert_eq(wire.contains("Content-Length: 6\r\n"), true)
  @test.assert_eq(wire.has_suffix("\r\n\r\n操作"), true)
}

///|
test "an empty body still announces a zero length" {
  let url = match @http.parse_url("http://a.test/x") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  let wire = @http.render_request("PUT", url, "", Some(""))
  @test.assert_eq(wire.contains("Content-Length: 0\r\n"), true)
}

///|
test "a body does not duplicate a caller content-length" {
  let url = match @http.parse_url("http://a.test/x") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  let wire = @http.render_request(
    "POST",
    url,
    "Content-Length: 99\n",
    Some("hi"),
  )
  @test.assert_eq(wire.contains("Content-Length: 2\r\n"), true)
  @test.assert_eq(wire.contains("99"), false)
}

///|
test "a caller host wins over the url host" {
  let url = match @http.parse_url("http://a.test/x") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  let wire = @http.render_request("GET", url, "Host: virtual.test\n", None)
  @test.assert_eq(wire.contains("Host: virtual.test\r\n"), true)
  @test.assert_eq(wire.contains("Host: a.test"), false)
}

///|
test "a caller transfer-encoding is never forwarded" {
  let url = match @http.parse_url("http://a.test/x") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  let wire = @http.render_request(
    "POST",
    url,
    "Transfer-Encoding: chunked\n",
    Some("hi"),
  )
  @test.assert_eq(wire.contains("Transfer-Encoding"), false)
  @test.assert_eq(wire.contains("Content-Length: 2\r\n"), true)
}

///|
test "caller defaults replace the automatic ones" {
  let url = match @http.parse_url("http://a.test/x") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  let block = "User-Agent: probe/9\nAccept: text/plain\nConnection: keep-alive\nX-Trace: 1\n"
  let wire = @http.render_request("GET", url, block, None)
  @test.assert_eq(wire.contains("User-Agent: probe/9\r\n"), true)
  @test.assert_eq(wire.contains("moonprobe/0.2.0"), false)
  @test.assert_eq(wire.contains("Accept: text/plain\r\n"), true)
  @test.assert_eq(wire.contains("Connection: keep-alive\r\n"), true)
  @test.assert_eq(wire.contains("Connection: close"), false)
  @test.assert_eq(wire.contains("X-Trace: 1\r\n"), true)
}

///|
test "an ipv6 host is bracketed in the host header" {
  let url = match @http.parse_url("http://[::1]:8080/x") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  let wire = @http.render_request("GET", url, "", None)
  @test.assert_eq(wire.contains("Host: [::1]:8080\r\n"), true)
}

///|
test "the method is upper-cased on the request line" {
  let url = match @http.parse_url("https://a.test/x") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  let wire = @http.render_request("delete", url, "", None)
  @test.assert_eq(wire.has_prefix("DELETE /x HTTP/1.1\r\n"), true)
}

///|
test "send_with renders the request and parses the reply" {
  let seen : Array[String] = []
  let exchange = fn(wire : String) -> Result[Bytes, String] {
    seen.push(wire)
    Ok(utf8("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
  }
  let response = match
    @http.send_with(exchange, "get", "http://a.test/x", "", None) {
    Ok(value) => value
    Err(msg) => fail("exchange should succeed: \{msg}")
  }
  @test.assert_eq(seen.length(), 1)
  @test.assert_eq(seen[0], FX_WIRE_GET)
  @test.assert_eq(response.status, 200)
  @test.assert_eq(response.body, "ok")
}

///|
test "send_with passes the 100 continue reply through the parser" {
  let exchange = fn(_wire : String) -> Result[Bytes, String] {
    Ok(
      utf8(
        "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
      ),
    )
  }
  let response = match
    @http.send_with(exchange, "POST", "http://a.test/x", "", Some("hi")) {
    Ok(value) => value
    Err(msg) => fail("exchange should succeed: \{msg}")
  }
  @test.assert_eq(response.status, 200)
  @test.assert_eq(response.body, "ok")
  @test.assert_eq(response.interim, 1)
}

///|
test "send_with propagates a transport error" {
  let exchange = fn(_wire : String) -> Result[Bytes, String] {
    Err("connection refused")
  }
  match @http.send_with(exchange, "GET", "http://a.test/x", "", None) {
    Ok(_) => fail("a transport error must surface")
    Err(msg) => @test.assert_eq(msg, "connection refused")
  }
}

///|
test "send_with rejects an invalid url before exchanging" {
  let calls : Array[String] = []
  let exchange = fn(wire : String) -> Result[Bytes, String] {
    calls.push(wire)
    Ok(utf8(""))
  }
  match @http.send_with(exchange, "GET", "/relative", "", None) {
    Ok(_) => fail("a relative url must not be sent")
    Err(msg) => @test.assert_eq(msg.has_prefix("url \"/relative\""), true)
  }
  @test.assert_eq(calls.length(), 0)
}
