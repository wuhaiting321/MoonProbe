/// MoonProbe - url tests
///
/// Unit tests for RFC 3986 parsing. The cases that matter most for the
/// 10-month harden work are the fragment-preserving ones: a fragment must stay
/// in the `Url` value (so a copied URL round-trips) and must never reach the
/// request-target (so the server is not asked to interpret it).

///|
test "parse a plain https url" {
  let url = match @http.parse_url("https://api.example.com/v1/users") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  @test.assert_eq(url.scheme, "https")
  @test.assert_eq(url.host, "api.example.com")
  @test.assert_eq(url.port, 443)
  @test.assert_eq(url.path, "/v1/users")
  @test.assert_eq(url.query, None)
  @test.assert_eq(url.fragment, None)
  @test.assert_eq(url.is_tls(), true)
}

///|
test "parse a http url with an explicit port" {
  let url = match @http.parse_url("http://api.example.com:8080/ping") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  @test.assert_eq(url.port, 8080)
  @test.assert_eq(url.host_header(), "api.example.com:8080")
  @test.assert_eq(url.is_tls(), false)
}

///|
test "an empty path becomes the root" {
  let url = match @http.parse_url("https://api.example.com") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  @test.assert_eq(url.path, "/")
}

///|
test "the query is split before the fragment" {
  let url = match
    @http.parse_url("https://a.test/search?q=moonbit&page=2#results") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  @test.assert_eq(url.path, "/search")
  @test.assert_eq(url.query, Some("q=moonbit&page=2"))
  @test.assert_eq(url.fragment, Some("results"))
}

///|
test "a fragment before a question mark is not a query" {
  let url = match @http.parse_url("https://a.test/doc#frag?q=1") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  @test.assert_eq(url.path, "/doc")
  @test.assert_eq(url.query, None)
  @test.assert_eq(url.fragment, Some("frag?q=1"))
}

///|
test "the fragment is preserved but never sent" {
  let url = match @http.parse_url("https://a.test/path?x=1#section") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  @test.assert_eq(url.fragment, Some("section"))
  @test.assert_eq(url.request_target(), "/path?x=1")
}

///|
test "an empty fragment is still preserved" {
  let url = match @http.parse_url("https://a.test/path#") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  @test.assert_eq(url.fragment, Some(""))
  @test.assert_eq(url.request_target(), "/path")
}

///|
test "the request target keeps the exact query text" {
  let url = match @http.parse_url("https://a.test/q?a=1&b=%20&c") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  @test.assert_eq(url.request_target(), "/q?a=1&b=%20&c")
}

///|
test "the default port is omitted from the host header" {
  let url = match @http.parse_url("https://a.test:443/x") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  @test.assert_eq(url.port, 443)
  @test.assert_eq(url.host_header(), "a.test")
}

///|
test "parse an IPv6 host with a port" {
  let url = match @http.parse_url("http://[::1]:8080/x") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  @test.assert_eq(url.host, "::1")
  @test.assert_eq(url.ipv6, true)
  @test.assert_eq(url.port, 8080)
  @test.assert_eq(url.host_header(), "[::1]:8080")
}

///|
test "parse an IPv6 host without a port" {
  let url = match @http.parse_url("http://[::1]/x") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  @test.assert_eq(url.host, "::1")
  @test.assert_eq(url.port, 80)
  @test.assert_eq(url.host_header(), "[::1]")
}

///|
test "user info is accepted and dropped" {
  let url = match @http.parse_url("https://user:secret@a.test/x") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  @test.assert_eq(url.host, "a.test")
  @test.assert_eq(url.host_header(), "a.test")
}

///|
test "user info with an at sign in the password uses the last at" {
  let url = match @http.parse_url("https://user:p@ss@a.test/x") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  @test.assert_eq(url.host, "a.test")
}

///|
test "the scheme is lower-cased" {
  let url = match @http.parse_url("HTTPS://A.TEST/x") {
    Ok(value) => value
    Err(msg) => fail("url should parse: \{msg}")
  }
  @test.assert_eq(url.scheme, "https")
  @test.assert_eq(url.is_tls(), true)
}

///|
test "a relative url is rejected" {
  match @http.parse_url("/v1/users") {
    Ok(_) => fail("a relative url must not parse")
    Err(msg) =>
      @test.assert_eq(msg.has_prefix("url \"/v1/users\" is not absolute"), true)
  }
}

///|
test "an unsupported scheme is rejected" {
  match @http.parse_url("ftp://a.test/x") {
    Ok(_) => fail("ftp must not parse")
    Err(msg) =>
      @test.assert_eq(
        msg, "unsupported url scheme \"ftp\": only http and https are supported",
      )
  }
}

///|
test "an empty host is rejected" {
  match @http.parse_url("https:///x") {
    Ok(_) => fail("an empty host must not parse")
    Err(msg) => @test.assert_eq(msg.has_prefix("url \"https:///x\""), true)
  }
}

///|
test "a non-numeric port is rejected" {
  match @http.parse_url("https://a.test:abc/x") {
    Ok(_) => fail("a non-numeric port must not parse")
    Err(msg) =>
      @test.assert_eq(
        msg, "url \"https://a.test:abc/x\": invalid port \"abc\": expected digits",
      )
  }
}

///|
test "port zero is rejected" {
  match @http.parse_url("https://a.test:0/x") {
    Ok(_) => fail("port zero must not parse")
    Err(msg) =>
      @test.assert_eq(
        msg, "url \"https://a.test:0/x\": invalid port \"0\": must be between 1 and 65535",
      )
  }
}

///|
test "a port above 65535 is rejected" {
  match @http.parse_url("https://a.test:70000/x") {
    Ok(_) => fail("an out-of-range port must not parse")
    Err(_) => ()
  }
}

///|
test "an unterminated IPv6 host is rejected" {
  match @http.parse_url("http://[::1/x") {
    Ok(_) => fail("an unterminated IPv6 host must not parse")
    Err(msg) =>
      @test.assert_eq(
        msg, "url \"http://[::1/x\" has an unterminated IPv6 host",
      )
  }
}

///|
test "the default port table follows the scheme" {
  @test.assert_eq(@http.default_port("http"), 80)
  @test.assert_eq(@http.default_port("https"), 443)
}
