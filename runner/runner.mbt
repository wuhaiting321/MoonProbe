/// MoonProbe - runner
///
/// Executes a parsed `.probe` case: it resolves the AST request into a concrete
/// HTTP call, hands that call to the platform transport and reports a
/// structured response.
///
/// Everything that decides *what* to send lives in this file and is free of
/// platform FFI, so it stays testable on every backend. `send` — the one
/// function that actually touches the network — is implemented per target in
/// `http_js.mbt` and `http_stub.mbt`, and exchanges `(status, body)` primitives
/// so that no transport type leaks into the shared code.
///
/// A request may reference variables bound by earlier cases: `{{token}}` inside
/// a URL, header value, query value or body is replaced with the value the
/// context holds for `token` before the request is sent.

/// A structured HTTP response.
pub struct Response {
  /// The HTTP status code reported by the server.
  status : Int
  /// The raw response body, as text.
  body : String
}

/// An empty variable context, ready to be threaded through a whole suite.
pub fn new_context() -> Map[String, String] {
  return Map([])
}

/// The default per-request timeout, in milliseconds.
pub const DEFAULT_TIMEOUT_MS : Int = 5000

/// Whether `code` may appear literally inside a URL query component.
///
/// This is the RFC 3986 "unreserved" set: ALPHA / DIGIT / "-" / "." / "_" / "~".
fn is_unreserved(code : Int) -> Bool {
  (code >= 0x41 && code <= 0x5a) ||
  (code >= 0x61 && code <= 0x7a) ||
  (code >= 0x30 && code <= 0x39) ||
  code == 0x2d ||
  code == 0x5f ||
  code == 0x2e ||
  code == 0x7e
}

/// The upper-case hexadecimal digit for a value in `0..=15`.
fn hex_digit(value : Int) -> String {
  return "0123456789ABCDEF".get_char(value).unwrap().to_string()
}

/// Encode a single UTF-8 byte as one URL component: the character itself when
/// it belongs to the unreserved set, `%XX` otherwise.
fn encode_byte(byte : Int) -> String {
  if is_unreserved(byte) {
    return byte.to_char().unwrap().to_string()
  }
  return "%" + hex_digit(byte / 16) + hex_digit(byte % 16)
}

/// Percent-encode one URL component, leaving unreserved characters untouched.
///
/// Each character is expanded to its UTF-8 bytes first, so non-ASCII text
/// percent-encodes to the same form a browser would produce.
fn url_encode(s : String) -> String {
  let mut out = ""
  for c in s {
    let code = c.to_int()
    if code < 0x80 {
      out = out + encode_byte(code)
    } else if code < 0x800 {
      let b1 = encode_byte(0xc0 | (code >> 6))
      let b2 = encode_byte(0x80 | (code & 0x3f))
      out = out + b1 + b2
    } else if code < 0x10000 {
      let b1 = encode_byte(0xe0 | (code >> 12))
      let b2 = encode_byte(0x80 | ((code >> 6) & 0x3f))
      let b3 = encode_byte(0x80 | (code & 0x3f))
      out = out + b1 + b2 + b3
    } else {
      let b1 = encode_byte(0xf0 | (code >> 18))
      let b2 = encode_byte(0x80 | ((code >> 12) & 0x3f))
      let b3 = encode_byte(0x80 | ((code >> 6) & 0x3f))
      let b4 = encode_byte(0x80 | (code & 0x3f))
      out = out + b1 + b2 + b3 + b4
    }
  }
  return out
}

/// Substitute every `{{name}}` placeholder in `text` with the value bound to
/// `name` in `context`.
///
/// A placeholder whose name is not bound is left verbatim, so a typo shows up in
/// the request that is actually sent instead of silently becoming an empty
/// string.
fn interpolate(text : String, context : Map[String, String]) -> String {
  if !text.contains_char('{') {
    return text
  }
  let mut out = ""
  let mut first = true
  for part in text.split("{{") {
    if first {
      // The text before the first placeholder is literal.
      out = out + part.to_owned()
      first = false
      continue
    }
    let segment = part.to_owned()
    match segment.split_once("}}") {
      Some((name, rest)) => {
        let key = name.trim().to_owned()
        match context.get(key) {
          Some(value) => out = out + value + rest.to_owned()
          None => out = out + "{{" + segment
        }
      }
      None => out = out + "{{" + segment
    }
  }
  return out
}

/// Append the declared query parameters to the request URL, percent-encoding
/// each key and value.
pub fn build_url(
  request : @parser.Request,
  context : Map[String, String]
) -> String {
  let base = interpolate(request.url, context)
  if request.query.length() == 0 {
    return base
  }
  let mut out = base
  if base.contains_char('?') {
    out = out + "&"
  } else {
    out = out + "?"
  }
  let mut i = 0
  while i < request.query.length() {
    if i > 0 {
      out = out + "&"
    }
    let pair = request.query[i]
    out = out +
      url_encode(interpolate(pair.key, context)) +
      "=" +
      url_encode(interpolate(pair.value, context))
    i = i + 1
  }
  return out
}

/// Serialise headers into `Name: value` lines separated by newlines, expanding
/// any `{{name}}` placeholder in a header value.
///
/// The transport receives them as a single string so that the FFI boundary only
/// has to exchange primitives.
fn header_lines(
  headers : Array[@parser.Pair],
  context : Map[String, String]
) -> String {
  let mut out = ""
  let mut i = 0
  while i < headers.length() {
    if i > 0 {
      out = out + "\n"
    }
    out = out + headers[i].key + ": " + interpolate(headers[i].value, context)
    i = i + 1
  }
  return out
}

/// Perform one HTTP request, aborting after `timeout_ms` milliseconds.
///
/// The request is resolved here — URL, headers, body and any `{{name}}`
/// reference — and then handed to the per-target `send`, which is the only part
/// that needs a platform transport.
pub fn run_request(
  request : @parser.Request,
  context : Map[String, String],
  timeout_ms? : Int = DEFAULT_TIMEOUT_MS
) -> Result[Response, String] {
  match send(
    request.http_method,
    build_url(request, context),
    header_lines(request.headers, context),
    interpolate(request.body.unwrap_or(""), context),
    timeout_ms,
  ) {
    Ok((status, body)) => Ok({ status: status, body: body })
    Err(msg) => Err(msg)
  }
}