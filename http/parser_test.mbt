/// MoonProbe - http response tests
///
/// Every test hands `parse_response` a scripted byte stream, which is the whole
/// reason the protocol lives above the socket: framing, interim responses and
/// truncation are decided here and can be exercised on `wasm-gc`.

///|
/// Encode the scripted replies below as the bytes a connection would deliver.
fn utf8(text : String) -> Bytes {
  return @utf8.encode(text)
}

///|
/// The header value of `name`, or `None`.
fn header_of(response : Response, name : String) -> String? {
  for pair in response.headers {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  return None
}

///|
test "parse a plain content-length response" {
  let raw = utf8(
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\nhi",
  )
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.status, 200)
  @test.assert_eq(response.reason, "OK")
  @test.assert_eq(response.body, "hi")
  @test.assert_eq(response.interim, 0)
  @test.assert_eq(response.headers.length(), 2)
  @test.assert_eq(header_of(response, "Content-Type"), Some("application/json"))
}

///|
test "skip a 100 Continue interim response" {
  // The old curl transport leaked the interim header block into the body. The
  // parser must consume it and report only the final response.
  let raw = utf8(
    "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
  )
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.status, 200)
  @test.assert_eq(response.body, "hello")
  @test.assert_eq(response.interim, 1)
}

///|
test "skip several interim responses" {
  let raw = utf8(
    "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </s.css>\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok",
  )
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.status, 201)
  @test.assert_eq(response.body, "ok")
  @test.assert_eq(response.interim, 2)
}

///|
test "101 is a final response, not an interim one" {
  let raw = utf8(
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
  )
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.status, 101)
  @test.assert_eq(response.interim, 0)
  @test.assert_eq(response.body, "")
}

///|
test "parse a chunked body with extensions and trailers" {
  let raw = utf8(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;name=value\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: ignored\r\n\r\n",
  )
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.status, 200)
  @test.assert_eq(response.body, "hello world")
}

///|
test "parse an upper-case hexadecimal chunk size" {
  let raw = utf8(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nA\r\n0123456789\r\n0\r\n\r\n",
  )
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.body, "0123456789")
}

///|
test "a chunked body without trailers ends after the zero chunk" {
  let raw = utf8(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n",
  )
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.body, "ok")
}

///|
test "chunked wins over content-length" {
  let raw = utf8(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n",
  )
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.body, "ok")
}

///|
test "content-length frames the body exactly" {
  let raw = utf8("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabcdef")
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.body, "abc")
}

///|
test "a response without framing is delimited by eof" {
  let raw = utf8("HTTP/1.1 200 OK\r\n\r\nuntil the end")
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.body, "until the end")
}

///|
test "204 never carries a body" {
  let raw = utf8("HTTP/1.1 204 No Content\r\nContent-Length: 5\r\n\r\nhello")
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.status, 204)
  @test.assert_eq(response.body, "")
}

///|
test "304 never carries a body" {
  let raw = utf8("HTTP/1.1 304 Not Modified\r\nContent-Length: 5\r\n\r\nhello")
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.status, 304)
  @test.assert_eq(response.body, "")
}

///|
test "a response to HEAD never carries a body" {
  let raw = utf8("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n")
  let response = match parse_response(raw, http_method="HEAD") {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.body, "")
}

///|
test "an obsolete folded header is joined" {
  let raw = utf8(
    "HTTP/1.1 200 OK\r\nX-Note: first\r\n  second\r\nContent-Length: 2\r\n\r\nok",
  )
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(header_of(response, "X-Note"), Some("first second"))
}

///|
test "header names are matched case-insensitively for framing" {
  let raw = utf8("HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.body, "ok")
}

///|
test "conflicting content-length values are rejected" {
  let raw = utf8(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\nok",
  )
  match parse_response(raw) {
    Ok(_) => fail("conflicting lengths must not parse")
    Err(msg) =>
      @test.assert_eq(msg, "conflicting Content-Length values: 2 and 3")
  }
}

///|
test "duplicate identical content-length values are accepted" {
  let raw = utf8(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nok",
  )
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.body, "ok")
}

///|
test "a non-numeric content-length is rejected" {
  let raw = utf8("HTTP/1.1 200 OK\r\nContent-Length: two\r\n\r\nok")
  match parse_response(raw) {
    Ok(_) => fail("a non-numeric length must not parse")
    Err(msg) =>
      @test.assert_eq(msg, "invalid Content-Length \"two\": expected digits")
  }
}

///|
test "a truncated content-length body is rejected" {
  let raw = utf8("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nok")
  match parse_response(raw) {
    Ok(_) => fail("a truncated body must not parse")
    Err(msg) => @test.assert_eq(msg.has_prefix("the message ended early"), true)
  }
}

///|
test "a truncated chunk is rejected" {
  let raw = utf8("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nok")
  match parse_response(raw) {
    Ok(_) => fail("a truncated chunk must not parse")
    Err(msg) => @test.assert_eq(msg.has_prefix("the message ended early"), true)
  }
}

///|
test "a chunk without trailing crlf is rejected" {
  let raw = utf8(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nokXX0\r\n\r\n",
  )
  match parse_response(raw) {
    Ok(_) => fail("a chunk without CRLF must not parse")
    Err(msg) =>
      @test.assert_eq(
        msg, "malformed chunk: the payload is not followed by CRLF",
      )
  }
}

///|
test "a malformed chunk size is rejected" {
  let raw = utf8(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nok\r\n0\r\n\r\n",
  )
  match parse_response(raw) {
    Ok(_) => fail("a malformed chunk size must not parse")
    Err(msg) => @test.assert_eq(msg.has_prefix("malformed chunk size"), true)
  }
}

///|
test "a malformed status line is rejected" {
  match parse_response(utf8("HTTP/1.1 OK\r\n\r\n")) {
    Ok(_) => fail("a status line without a code must not parse")
    Err(msg) => @test.assert_eq(msg.has_prefix("malformed status line"), true)
  }
}

///|
test "a non-http status line is rejected" {
  match parse_response(utf8("SSH-2.0-OpenSSH\r\n\r\n")) {
    Ok(_) => fail("a non-http status line must not parse")
    Err(msg) => @test.assert_eq(msg.has_prefix("malformed status line"), true)
  }
}

///|
test "a header line without a colon is rejected" {
  let raw = utf8("HTTP/1.1 200 OK\r\nBroken-Header\r\n\r\n")
  match parse_response(raw) {
    Ok(_) => fail("a header without a colon must not parse")
    Err(msg) => @test.assert_eq(msg.has_prefix("malformed header line"), true)
  }
}

///|
test "an empty header name is rejected" {
  let raw = utf8("HTTP/1.1 200 OK\r\n: value\r\n\r\n")
  match parse_response(raw) {
    Ok(_) => fail("an empty header name must not parse")
    Err(msg) => @test.assert_eq(msg.has_prefix("malformed header line"), true)
  }
}

///|
test "bare line feeds are accepted" {
  let raw = utf8("HTTP/1.1 200 OK\nContent-Length: 2\n\nok")
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.body, "ok")
}

///|
test "an empty reason phrase is accepted" {
  let raw = utf8("HTTP/1.1 200 \r\nContent-Length: 0\r\n\r\n")
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.status, 200)
  @test.assert_eq(response.reason, "")
  @test.assert_eq(response.body, "")
}

///|
test "a body decoded as utf-8 keeps non-ascii text" {
  let raw = utf8("HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\n操作成功")
  let response = match parse_response(raw) {
    Ok(value) => value
    Err(msg) => fail("response should parse: \{msg}")
  }
  @test.assert_eq(response.body, "操作成功")
}
