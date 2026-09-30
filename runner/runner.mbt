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

///|
/// A structured HTTP response.
pub struct Response {
  /// The HTTP status code reported by the server.
  status : Int
  /// The response headers, in the order the server sent them. Names are kept as
  /// the server spelled them; every lookup in this package folds ASCII case.
  headers : Array[(String, String)]
  /// The raw response body, as text.
  body : String
}

///|
/// An empty variable context, ready to be threaded through a whole suite.
pub fn new_context() -> Map[String, String] {
  return Map([])
}

///|
/// The default per-request timeout, in milliseconds.
pub const DEFAULT_TIMEOUT_MS : Int = 5000

///|
/// Look an environment variable up in the real environment.
///
/// The runner never calls this directly: placeholder expansion takes an
/// environment lookup as a parameter so that the substitution rules stay
/// testable on backends that have no environment at all. This is the lookup the
/// real run uses.
pub fn system_env(key : String) -> String? {
  return @env.get_env_var(key)
}

///|
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

///|
/// The upper-case hexadecimal digit for a value in `0..=15`.
fn hex_digit(value : Int) -> String {
  return "0123456789ABCDEF".get_char(value).unwrap().to_string()
}

///|
/// Encode a single UTF-8 byte as one URL component: the character itself when
/// it belongs to the unreserved set, `%XX` otherwise.
fn encode_byte(byte : Int) -> String {
  if is_unreserved(byte) {
    return byte.to_char().unwrap().to_string()
  }
  return "%" + hex_digit(byte / 16) + hex_digit(byte % 16)
}

///|
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

///|
/// Substitute every placeholder of `text`.
///
/// Two channels are supported and may be mixed freely:
///
///   - `{{name}}`        a variable the run bound earlier, via `set:`
///   - `${NAME}`         an environment variable of the process
///   - `${NAME:-value}`  ... or `value` when that variable is not set
///
/// The scan is a single left-to-right pass, so a value that happens to look
/// like a placeholder — a token containing `${...}`, say — is copied verbatim
/// instead of being expanded a second time.
///
/// An `Err` names the one variable that could have been provided but was not:
/// a `{{name}}` with no binding is deliberately left verbatim (a typo should be
/// visible in the request that was sent), while a `${NAME}` with no value and no
/// fallback stops the request with an actionable message.
pub fn resolve_placeholders(
  text : String,
  context : Map[String, String],
  env : (String) -> String?,
) -> Result[String, String] {
  if !text.contains_char('{') {
    return Ok(text)
  }
  let buf = StringBuilder()
  let n = text.length()
  let mut i = 0
  while i < n {
    let code = text.at(i).to_int()
    // `{{` opens a variable reference, `${` an environment reference.
    if code == OPEN_BRACE && i + 1 < n && text.at(i + 1).to_int() == OPEN_BRACE {
      match read_until(text, i + 2, "}}") {
        Some((inner, next)) => {
          let key = inner.trim().to_owned()
          match context.get(key) {
            Some(value) => buf.write_string(value)
            None => buf.write_string("{{" + inner + "}}")
          }
          i = next
        }
        None =>
          return Err(
            "unterminated variable reference (missing \"}}\") in \"" +
            text +
            "\"",
          )
      }
      continue
    }
    if code == DOLLAR && i + 1 < n && text.at(i + 1).to_int() == OPEN_BRACE {
      match read_until(text, i + 2, "}") {
        Some((inner, next)) => {
          let name = env_name_of(inner)
          if name.length() == 0 {
            return Err("empty environment reference in \"" + text + "\"")
          }
          match env(name) {
            Some(value) => buf.write_string(value)
            None =>
              match env_fallback_of(inner) {
                Some(fallback) => buf.write_string(fallback)
                None => {
                  // The suggested form is assembled around a `$` taken from its
                  // code point rather than written out: a source literal that
                  // spells the whole `${...}` shape gets folded into a JS
                  // template literal by the `js` backend, where that `$` would
                  // open an interpolation instead of being a dollar sign.
                  let dollar = (0x24).to_char().unwrap().to_string()
                  let hint = dollar + "{" + name + ":-fallback}"
                  return Err(
                    "environment variable \"" +
                    name +
                    "\" is not set (declare a default as " +
                    hint +
                    ")",
                  )
                }
              }
          }
          i = next
        }
        None =>
          return Err(
            "unterminated environment reference (missing \"}\") in \"" +
            text +
            "\"",
          )
      }
      continue
    }
    buf.write_char(code.to_char().unwrap())
    i = i + 1
  }
  return Ok(buf.to_string())
}

///|
/// The opening brace shared by `{{name}}` and `${NAME}`.
const OPEN_BRACE : Int = 0x7b

///|
/// The `$` that opens an environment reference.
const DOLLAR : Int = 0x24

///|
/// Read the characters of `text` from `start` up to the next occurrence of
/// `closer`, returning the text before it and the index just past it.
///
/// Returns `None` when `closer` never appears, which is how an unterminated
/// placeholder is detected. `closer` is one or two characters long, which is all
/// the grammar needs.
fn read_until(text : String, start : Int, closer : String) -> (String, Int)? {
  let width = closer.length()
  let first = closer.at(0).to_int()
  let buf = StringBuilder()
  let mut i = start
  while i < text.length() {
    if text.at(i).to_int() == first {
      let closed = width == 1 ||
        (
          i + 1 < text.length() &&
          text.at(i + 1).to_int() == closer.at(1).to_int()
        )
      if closed {
        return Some((buf.to_string(), i + width))
      }
    }
    buf.write_char(text.at(i).to_int().to_char().unwrap())
    i = i + 1
  }
  return None
}

///|
/// The variable name of an environment reference, i.e. the part before the
/// optional `:-` fallback separator.
fn env_name_of(inner : String) -> String {
  match inner.split_once(":-") {
    Some((name, _)) => name.trim().to_owned()
    None => inner.trim().to_owned()
  }
}

///|
/// The fallback of an environment reference, or `None` when it declares none.
///
/// The fallback is taken verbatim — it is not scanned for further placeholders,
/// so `${PATH:-/usr/bin}` means exactly that even if `/usr/bin` were to contain
/// a placeholder-like sequence.
fn env_fallback_of(inner : String) -> String? {
  match inner.split_once(":-") {
    Some((_, fallback)) => Some(fallback.to_owned())
    None => None
  }
}

// ---------------------------------------------------------------------------
// Config resolution
// ---------------------------------------------------------------------------

///|
/// A case request after the suite config has been merged into it.
///
/// The merge is the reason this type exists: a `.probe` author writes the shared
/// half of a suite once, in the `config:` block, and each case only spells out
/// what differs. Everything here is still unresolved text — placeholders are
/// expanded later, at send time — so a base URL may itself contain `${...}`.
pub struct ResolvedRequest {
  /// HTTP verb to send.
  http_method : String
  /// Absolute URL, built from `base_url` and the case's `url:` when needed.
  url : String
  /// Global headers first, then the case's own; a case header replaces a global
  /// one with the same name, keeping the global position.
  headers : Array[(String, String)]
  /// Query parameters of the case alone: the config block declares none.
  query : Array[(String, String)]
  /// Raw request body, or the empty string when the case declared none.
  body : String
  /// Effective timeout, in milliseconds.
  timeout_ms : Int
}

///|
/// Whether two strings are equal when ASCII case is folded on both sides.
///
/// Header names are case-insensitive per RFC 9110, so this is what decides
/// whether a case header overrides a global one and whether a response carries
/// the header an extraction asked for.
fn equals_ignore_case(left : String, right : String) -> Bool {
  if left.length() != right.length() {
    return false
  }
  let mut i = 0
  while i < left.length() {
    if fold_ascii(left.at(i).to_int()) != fold_ascii(right.at(i).to_int()) {
      return false
    }
    i = i + 1
  }
  return true
}

///|
/// Fold one ASCII letter to lower case, leaving every other code point alone.
fn fold_ascii(code : Int) -> Int {
  if code >= 0x41 && code <= 0x5a {
    return code + 0x20
  }
  return code
}

///|
/// Whether `text` starts with `prefix`, ignoring ASCII case.
fn has_prefix_ignore_case(text : String, prefix : String) -> Bool {
  if text.length() < prefix.length() {
    return false
  }
  return equals_ignore_case(
    text.view(end_offset=prefix.length()).to_owned(),
    prefix,
  )
}

///|
/// Whether a URL is absolute, i.e. carries its own scheme.
fn is_absolute_url(url : String) -> Bool {
  return has_prefix_ignore_case(url, "http://") ||
    has_prefix_ignore_case(url, "https://")
}

///|
/// Join a case's `url:` onto the suite's `base_url`.
///
/// An absolute `url:` is kept as it is, which is how one suite can point a
/// single case at a third-party service. A relative one needs a `base_url`, and
/// the seam between the two is normalised so that `https://a.test/` + `/users`
/// and `https://a.test` + `users` both yield `https://a.test/users`.
fn join_base_url(base : String?, url : String) -> Result[String, String] {
  if is_absolute_url(url) {
    return Ok(url)
  }
  let root = match base {
    Some(b) => b
    None =>
      return Err(
        "relative url \"\{url}\" needs a \"base_url\" in the config block",
      )
  }
  let mut trimmed = root
  while trimmed.length() > 0 &&
        trimmed.at(trimmed.length() - 1).to_int() == 0x2f {
    trimmed = trimmed.view(end_offset=trimmed.length() - 1).to_owned()
  }
  if url.length() == 0 {
    return Ok(trimmed)
  }
  if url.at(0).to_int() == 0x2f {
    return Ok(trimmed + url)
  }
  return Ok(trimmed + "/" + url)
}

///|
/// Merge the global headers with a case's own headers.
///
/// A case header with the same name as a global one replaces it in place, so the
/// global declaration order survives; the case's remaining headers are appended
/// after the globals.
fn merge_headers(
  globals : Array[@parser.Pair],
  locals : Array[@parser.Pair],
) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for header in globals {
    out.push((header.key, header.value))
  }
  for header in locals {
    let mut index = -1
    let mut i = 0
    while i < out.length() {
      if equals_ignore_case(out[i].0, header.key) {
        index = i
        break
      }
      i = i + 1
    }
    if index >= 0 {
      out[index] = (header.key, header.value)
    } else {
      out.push((header.key, header.value))
    }
  }
  return out
}

///|
/// Resolve a case request against the suite config.
///
/// Precedence, most specific first: the case's own `timeout:`, then the config
/// block's `global_timeout`, then the timeout the caller passed to the runner.
///
/// `Err` is returned for a request that cannot be turned into a call at all — a
/// relative URL with no `base_url` to resolve it against.
pub fn resolve_request(
  request : @parser.Request,
  config : @parser.Config,
  timeout_ms? : Int = DEFAULT_TIMEOUT_MS,
) -> Result[ResolvedRequest, String] {
  let url = match join_base_url(config.base_url, request.url) {
    Ok(u) => u
    Err(msg) => return Err(msg)
  }
  let effective = match request.timeout_ms {
    // A case-level timeout is the most specific, so it wins outright.
    Some(own) => own
    None =>
      match config.global_timeout_ms {
        Some(global) => global
        None => timeout_ms
      }
  }
  let query : Array[(String, String)] = []
  for pair in request.query {
    query.push((pair.key, pair.value))
  }
  return Ok({
    http_method: request.http_method,
    url,
    headers: merge_headers(config.global_headers, request.headers),
    query,
    body: request.body.unwrap_or(""),
    timeout_ms: effective,
  })
}

// ---------------------------------------------------------------------------
// Placeholder expansion and the transport call
// ---------------------------------------------------------------------------

///|
/// Append the resolved query parameters to the URL, percent-encoding each key
/// and value and expanding every placeholder on the way.
pub fn build_url(
  resolved : ResolvedRequest,
  context : Map[String, String],
  env : (String) -> String?,
) -> Result[String, String] {
  let base = match resolve_placeholders(resolved.url, context, env) {
    Ok(text) => text
    Err(msg) => return Err(msg)
  }
  if resolved.query.length() == 0 {
    return Ok(base)
  }
  let buf = StringBuilder()
  buf.write_string(base)
  if base.contains_char('?') {
    buf.write_char('&')
  } else {
    buf.write_char('?')
  }
  let mut i = 0
  while i < resolved.query.length() {
    if i > 0 {
      buf.write_char('&')
    }
    let (key, value) = resolved.query[i]
    let expanded_key = match resolve_placeholders(key, context, env) {
      Ok(text) => text
      Err(msg) => return Err(msg)
    }
    let expanded_value = match resolve_placeholders(value, context, env) {
      Ok(text) => text
      Err(msg) => return Err(msg)
    }
    buf.write_string(url_encode(expanded_key))
    buf.write_char('=')
    buf.write_string(url_encode(expanded_value))
    i = i + 1
  }
  return Ok(buf.to_string())
}

///|
/// Serialise headers into `Name: value` lines separated by newlines, expanding
/// every placeholder in a header value.
///
/// Header *names* are never expanded: a name that could change per run would
/// make the request unreviewable, and no server needs it. The transport receives
/// the result as a single string so that the FFI boundary only has to exchange
/// primitives.
pub fn header_lines(
  resolved : ResolvedRequest,
  context : Map[String, String],
  env : (String) -> String?,
) -> Result[String, String] {
  let buf = StringBuilder()
  let mut i = 0
  while i < resolved.headers.length() {
    if i > 0 {
      buf.write_char('\n')
    }
    let (name, raw) = resolved.headers[i]
    let value = match resolve_placeholders(raw, context, env) {
      Ok(text) => text
      Err(msg) => return Err(msg)
    }
    buf.write_string(name + ": " + value)
    i = i + 1
  }
  return Ok(buf.to_string())
}

///|
/// Perform one HTTP request, aborting after the resolved timeout.
///
/// The request is resolved — config merge, base URL join, header merge,
/// placeholder expansion — and then handed to the per-target `send`, which is
/// the only part that needs a platform transport.
pub fn run_request(
  request : @parser.Request,
  config : @parser.Config,
  context : Map[String, String],
  timeout_ms? : Int = DEFAULT_TIMEOUT_MS,
) -> Result[Response, String] {
  let resolved = match resolve_request(request, config, timeout_ms~) {
    Ok(r) => r
    Err(msg) => return Err(msg)
  }
  let env : (String) -> String? = system_env
  let url = match build_url(resolved, context, env) {
    Ok(u) => u
    Err(msg) => return Err(msg)
  }
  let headers = match header_lines(resolved, context, env) {
    Ok(h) => h
    Err(msg) => return Err(msg)
  }
  let body = match resolve_placeholders(resolved.body, context, env) {
    Ok(b) => b
    Err(msg) => return Err(msg)
  }
  match send(resolved.http_method, url, headers, body, resolved.timeout_ms) {
    Ok((status, response_headers, response_body)) =>
      Ok({ status, headers: response_headers, body: response_body, })
    Err(msg) => Err(msg)
  }
}

// ---------------------------------------------------------------------------
// Response headers and cookies
// ---------------------------------------------------------------------------

///|
/// Split `s` at its first line break into `(first_line, rest)`.
///
/// Shared by the transport and by the header parser, so both agree on how a
/// reply is cut into lines.
fn split_first_line(s : String) -> (String, String) {
  match s.split_once("\n") {
    Some((head, rest)) => (head.to_owned(), rest.to_owned())
    None => (s, "")
  }
}

///|
/// Strip a trailing carriage return, so that a CRLF reply reads like an LF one.
fn strip_cr(line : String) -> String {
  if line.length() > 0 && line.at(line.length() - 1).to_int() == 0x0d {
    return line.view(end_offset=line.length() - 1).to_owned()
  }
  return line
}

///|
/// Split a raw reply that leads with its headers — what `curl -i` produces —
/// into the header list and the body.
///
/// The first line is the status line, which the transport reports separately, so
/// it is dropped here. Header folding (a continued line starting with a space)
/// is joined onto the previous value, which is what makes a multi-line
/// `Set-Cookie` readable as one header.
pub fn split_response_headers(
  raw : String,
) -> (Array[(String, String)], String) {
  let headers : Array[(String, String)] = []
  let (_, after_status) = split_first_line(raw)
  let mut rest = after_status
  while rest.length() > 0 {
    let (raw_line, tail) = split_first_line(rest)
    let line = strip_cr(raw_line)
    if line.trim().length() == 0 {
      // The blank line ends the header section.
      return (headers, tail)
    }
    // A folded continuation carries no `name:` of its own: it is more of the
    // value above it, so it is joined there instead of being parsed.
    if line.at(0).to_int() == 0x20 || line.at(0).to_int() == 0x09 {
      if headers.length() > 0 {
        let (previous_name, previous_value) = headers[headers.length() - 1]
        headers[headers.length() - 1] = (
          previous_name,
          previous_value + " " + line.trim().to_owned(),
        )
      }
      rest = tail
      continue
    }
    let (name, value) = match line.split_once(":") {
      Some((name, value)) => (name.trim().to_owned(), value.trim().to_owned())
      None => (line.trim().to_owned(), "")
    }
    if name.length() == 0 {
      return (headers, tail)
    }
    headers.push((name, value))
    rest = tail
  }
  return (headers, rest)
}

///|
/// Find a response header by name, ignoring ASCII case.
///
/// The first match wins, which is the value a client would use.
pub fn find_header(headers : Array[(String, String)], name : String) -> String? {
  for header in headers {
    if equals_ignore_case(header.0, name) {
      return Some(header.1)
    }
  }
  return None
}

///|
/// Find a cookie the server set, by cookie name.
///
/// Only the `Set-Cookie` headers are read, and only the `name=value` pair that
/// opens each one: the attributes that follow (`Path`, `HttpOnly`, ...) describe
/// the cookie rather than being part of its value. Cookie names are matched
/// exactly, because unlike header names they are case-sensitive.
pub fn find_cookie(headers : Array[(String, String)], name : String) -> String? {
  for header in headers {
    if !equals_ignore_case(header.0, "set-cookie") {
      continue
    }
    let pair = match header.1.split_once(";") {
      Some((pair, _)) => pair
      None => header.1
    }
    match pair.split_once("=") {
      Some((cookie_name, value)) =>
        if cookie_name.trim() == name {
          return Some(value.trim().to_owned())
        }
      None => ()
    }
  }
  return None
}

///|
/// Read the value a `set:` directive binds, out of a finished response.
///
/// The response arrives as its two readable halves — the header list and the
/// body — rather than as a whole `Response`, so that the extraction rules can be
/// exercised on every backend without a transport to produce a response first.
///
/// The three sources are tried in the order the directive names them, so the
/// failure message can say exactly which one came up empty — a missing header
/// and a missing field are different bugs and deserve different sentences.
pub fn extract_value(
  spec : @parser.SetSpec,
  headers : Array[(String, String)],
  body : String,
) -> Result[String, String] {
  match spec.source {
    @parser.FromBody => @assert.read_json_path(body, spec.path)
    @parser.FromHeader =>
      match find_header(headers, spec.path) {
        Some(value) => Ok(value)
        None => Err("header \"\{spec.path}\" is missing from the response")
      }
    @parser.FromCookie =>
      match find_cookie(headers, spec.path) {
        Some(value) => Ok(value)
        None =>
          Err(
            "cookie \"\{spec.path}\" was not set by the response (no matching Set-Cookie header)",
          )
      }
  }
}
