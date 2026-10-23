/// MoonProbe - http
///
/// RFC 3986 URL parsing for the requests a `.probe` file declares.
///
/// The parser keeps the fragment instead of dropping it: a fragment is part of
/// the URL a user wrote down, and silently losing it makes a copied URL stop
/// round-tripping. It is preserved in the `Url` value and deliberately left out
/// of `request_target` -- RFC 9112 says the request-target never carries one.
///
/// Query string and fragment are split strictly: `?q=1#frag` yields the query
/// `q=1` and the fragment `frag`, in that order. A `#` that appears before a
/// `?` ends the URL as far as the server is concerned, so `#frag?q=1` keeps
/// `frag?q=1` as the fragment and has no query at all.

///|
/// A parsed absolute URL.
pub struct Url {
  /// Lower-cased scheme, `http` or `https`.
  scheme : String
  /// Host without the IPv6 brackets.
  host : String
  /// Whether `host` came from `[ ... ]` and needs brackets when written back.
  ipv6 : Bool
  /// Effective port, with the scheme default already applied.
  port : Int32
  /// Request path, always starting with `/`.
  path : String
  /// Query string without the leading `?`.
  query : String?
  /// Fragment without the leading `#`. Kept, but never sent on the wire.
  fragment : String?
}

///|
/// The port a scheme uses when the URL does not name one.
pub fn default_port(scheme : String) -> Int32 {
  if scheme == "https" {
    return 443
  }
  return 80
}

///|
/// Whether `scheme` is one this client speaks.
fn is_supported_scheme(scheme : String) -> Bool {
  return scheme == "http" || scheme == "https"
}

///|
/// Find `needle` in `text` at or after `from`, returning its byte offset.
fn find_sub(text : String, needle : String, from : Int32) -> Int32? {
  let n = text.length()
  let m = needle.length()
  if m == 0 {
    return Some(from)
  }
  let mut i = from
  while i + m <= n {
    let mut j = 0
    let mut same = true
    while j < m {
      if text.at(i + j).to_int() != needle.at(j).to_int() {
        same = false
        break
      }
      j = j + 1
    }
    if same {
      return Some(i)
    }
    i = i + 1
  }
  return None
}

///|
/// Parse a decimal port number.
fn parse_port(text : String) -> Result[Int32, String] {
  if text.length() == 0 {
    return Err("empty port in url")
  }
  let mut value = 0
  let mut i = 0
  while i < text.length() {
    let c = text.at(i).to_int()
    if c < 0x30 || c > 0x39 {
      return Err("invalid port \"\{text}\": expected digits")
    }
    value = value * 10 + (c - 0x30)
    if value > 65535 {
      return Err("invalid port \"\{text}\": must be between 1 and 65535")
    }
    i = i + 1
  }
  if value == 0 {
    return Err("invalid port \"\{text}\": must be between 1 and 65535")
  }
  return Ok(value)
}

///|
/// Lower-case the ASCII letters of `text`, leaving everything else untouched.
fn ascii_lower(text : String) -> String {
  let buf = StringBuilder()
  for c in text {
    let code = c.to_int()
    if code >= 0x41 && code <= 0x5a {
      buf.write_char((code + 0x20).to_char().unwrap())
    } else {
      buf.write_char(c)
    }
  }
  return buf.to_string()
}

///|
/// Parse an absolute URL such as `https://api.example.com:8443/v1/users?q=1#top`.
///
/// User info (`user:pass@`) is accepted and ignored: it has no place in an
/// `Authorization` header this runner sets explicitly, and dropping it silently
/// is safer than sending credentials to an unintended host.
pub fn parse_url(raw : String) -> Result[Url, String] {
  let text = raw.trim().to_owned()
  if text.length() == 0 {
    return Err("empty url")
  }
  let sep = match find_sub(text, "://", 0) {
    Some(i) => i
    None =>
      return Err(
        "url \"\{raw}\" is not absolute: expected a scheme such as https://",
      )
  }
  let scheme = ascii_lower(text.view(start_offset=0, end_offset=sep).to_owned())
  if !is_supported_scheme(scheme) {
    return Err(
      "unsupported url scheme \"\{scheme}\": only http and https are supported",
    )
  }
  let n = text.length()
  // The authority ends at the first `/`, `?` or `#`.
  let mut auth_end = n
  let mut i = sep + 3
  while i < n {
    let c = text.at(i).to_int()
    if c == 0x2f || c == 0x3f || c == 0x23 {
      auth_end = i
      break
    }
    i = i + 1
  }
  let authority = text
    .view(start_offset=sep + 3, end_offset=auth_end)
    .to_owned()
  // Drop any user info: everything up to the last `@` in the authority.
  let host_part = match find_sub(authority, "@", 0) {
    Some(_) => {
      let mut cut = 0
      let mut k = 0
      while k < authority.length() {
        if authority.at(k).to_int() == 0x40 {
          cut = k + 1
        }
        k = k + 1
      }
      authority.view(start_offset=cut).to_owned()
    }
    None => authority
  }
  if host_part.length() == 0 {
    return Err("url \"\{raw}\" has no host")
  }
  let mut host = host_part
  let mut ipv6 = false
  let mut port_text : String? = None
  if host_part.at(0).to_int() == 0x5b {
    // `[ ... ]`, optionally followed by `:port`.
    let close = match find_sub(host_part, "]", 0) {
      Some(i) => i
      None => return Err("url \"\{raw}\" has an unterminated IPv6 host")
    }
    ipv6 = true
    host = host_part.view(start_offset=1, end_offset=close).to_owned()
    let tail = host_part.view(start_offset=close + 1).to_owned()
    if tail.length() > 0 {
      if tail.at(0).to_int() != 0x3a {
        return Err("url \"\{raw}\" has trailing text after the IPv6 host")
      }
      port_text = Some(tail.view(start_offset=1).to_owned())
    }
  } else {
    match find_sub(host_part, ":", 0) {
      Some(i) => {
        host = host_part.view(start_offset=0, end_offset=i).to_owned()
        port_text = Some(host_part.view(start_offset=i + 1).to_owned())
      }
      None => ()
    }
  }
  if host.length() == 0 {
    return Err("url \"\{raw}\" has no host")
  }
  let port = match port_text {
    Some(p) =>
      match parse_port(p) {
        Ok(v) => v
        Err(msg) => return Err("url \"\{raw}\": \{msg}")
      }
    None => default_port(scheme)
  }
  let tail = text.view(start_offset=auth_end).to_owned()
  let mut fragment : String? = None
  let mut before_fragment = tail
  match find_sub(tail, "#", 0) {
    Some(i) => {
      fragment = Some(tail.view(start_offset=i + 1).to_owned())
      before_fragment = tail.view(start_offset=0, end_offset=i).to_owned()
    }
    None => ()
  }
  let mut query : String? = None
  let mut path = before_fragment
  match find_sub(before_fragment, "?", 0) {
    Some(i) => {
      query = Some(before_fragment.view(start_offset=i + 1).to_owned())
      path = before_fragment.view(start_offset=0, end_offset=i).to_owned()
    }
    None => ()
  }
  if path.length() == 0 {
    path = "/"
  } else if path.at(0).to_int() != 0x2f {
    return Err("url \"\{raw}\": the path must start with \"/\"")
  }
  return Ok({ scheme, host, ipv6, port, path, query, fragment, })
}

///|
/// The host as it must appear in a `Host` header: IPv6 hosts are bracketed.
pub fn Url::host_header(self : Url) -> String {
  let name = if self.ipv6 { "[\{self.host}]" } else { self.host }
  if self.port == default_port(self.scheme) {
    return name
  }
  return "\{name}:\{self.port}"
}

///|
/// The request-target: the path plus the query string, never the fragment.
pub fn Url::request_target(self : Url) -> String {
  match self.query {
    Some(q) => return "\{self.path}?\{q}"
    None => return self.path
  }
}

///|
/// Whether the connection must be wrapped in TLS.
pub fn Url::is_tls(self : Url) -> Bool {
  return self.scheme == "https"
}
