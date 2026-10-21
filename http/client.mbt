/// MoonProbe - http
///
/// The request side of HTTP/1.1: turning a method, a parsed URL, a header block
/// and an optional body into the exact bytes a server expects.
///
/// Two decisions are worth spelling out.
///
///   - The request-target is `path?query`, never the fragment (§4 of RFC 9112).
///     The fragment is kept in the `Url` value so a user's URL round-trips, but
///     it has no meaning on the wire.
///   - The body is sent verbatim. The previous transport handed the body to
///     `curl --data-binary`, where a leading `@` means "read this file"; a body
///     like `{...}` was fine but a literal `@handle` silently uploaded a file
///     instead. Here a body is bytes, and nothing reinterprets its first
///     character.

///|
/// The byte-level transport: one rendered request in, the raw response out.
///
/// Keeping the protocol above this boundary is what lets `wasm-gc` tests drive
/// the whole client with scripted replies, and what lets the `js` backend swap
/// in a socket without the protocol knowing.
pub type Exchange = (String) -> Result[Bytes, String]

///|
/// Upper-case the ASCII letters of `text`.
fn ascii_upper(text : String) -> String {
  let buf = StringBuilder()
  for c in text {
    let code = c.to_int()
    if code >= 0x61 && code <= 0x7a {
      buf.write_char((code - 0x20).to_char().unwrap())
    } else {
      buf.write_char(c)
    }
  }
  return buf.to_string()
}

///|
/// Split a header block written as `Name: value` lines.
///
/// The runner already produces exactly that shape, so this is where the string
/// form becomes structured fields. A line without a colon keeps an empty value
/// rather than aborting: it is the request's own header, and an empty value is
/// a legal HTTP field value.
fn parse_header_block(block : String) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for line in block.split("\n") {
    let text = line.to_owned().trim().to_owned()
    if text.length() == 0 {
      continue
    }
    match find_sub(text, ":", 0) {
      Some(i) => {
        let name = text
          .view(start_offset=0, end_offset=i)
          .to_owned()
          .trim()
          .to_owned()
        let value = text.view(start_offset=i + 1).to_owned().trim().to_owned()
        out.push((name, value))
      }
      None => out.push((text, ""))
    }
  }
  return out
}

///|
/// Whether any field in `headers` is called `name`, ignoring ASCII case.
fn has_header(headers : Array[(String, String)], name : String) -> Bool {
  for pair in headers {
    if equals_ci(pair.0, name) {
      return true
    }
  }
  return false
}

///|
/// The value of the first field called `name`, if any.
fn first_header(headers : Array[(String, String)], name : String) -> String? {
  for pair in headers {
    if equals_ci(pair.0, name) {
      return Some(pair.1)
    }
  }
  return None
}

///|
/// Render an HTTP/1.1 request.
///
/// `Host` is mandatory in HTTP/1.1, so it is always written: a caller-supplied
/// one wins, otherwise it is derived from the URL (IPv6 hosts bracketed, and
/// the port omitted when it is the scheme default). `Connection: close` is the
/// default because this client reads a response until the server closes, which
/// is the only framing rule that needs no prior agreement.
pub fn render_request(
  http_method : String,
  url : Url,
  header_block : String,
  body : String?,
) -> String {
  let headers = parse_header_block(header_block)
  let buf = StringBuilder()
  buf.write_string(ascii_upper(http_method))
  buf.write_string(" ")
  buf.write_string(url.request_target())
  buf.write_string(" HTTP/1.1\r\n")
  let host = match first_header(headers, "Host") {
    Some(value) => value
    None => url.host_header()
  }
  buf.write_string("Host: \{host}\r\n")
  if !has_header(headers, "User-Agent") {
    buf.write_string("User-Agent: moonprobe/0.2.0\r\n")
  }
  if !has_header(headers, "Accept") {
    buf.write_string("Accept: */*\r\n")
  }
  if !has_header(headers, "Connection") {
    buf.write_string("Connection: close\r\n")
  }
  for pair in headers {
    // Host is already written; the framing headers are computed here so a case
    // can never announce a length that disagrees with the body it sends.
    if equals_ci(pair.0, "Host") ||
      equals_ci(pair.0, "Content-Length") ||
      equals_ci(pair.0, "Transfer-Encoding") {
      continue
    }
    buf.write_string(pair.0)
    buf.write_string(": ")
    buf.write_string(pair.1)
    buf.write_string("\r\n")
  }
  match body {
    Some(content) => {
      // Content-Length is a byte count, not a character count: `String::length`
      // counts UTF-16 code units, so a body of four CJK characters is two units
      // but twelve bytes. Sending the unit count would make a server wait for
      // ten bytes that never arrive.
      let byte_length = @utf8.encode(content).length()
      buf.write_string("Content-Length: \{byte_length}\r\n")
      buf.write_string("\r\n")
      buf.write_string(content)
    }
    None => buf.write_string("\r\n")
  }
  return buf.to_string()
}

///|
/// Send one request through `exchange` and parse the reply.
///
/// The exchange is the only part a test has to fake: give it the rendered
/// request it receives and answer with the raw bytes a server would have sent.
pub fn send_with(
  exchange : Exchange,
  http_method : String,
  raw_url : String,
  header_block : String,
  body : String?,
) -> Result[Response, String] {
  let url = match parse_url(raw_url) {
    Ok(value) => value
    Err(msg) => return Err(msg)
  }
  let wire = render_request(http_method, url, header_block, body)
  let raw = match exchange(wire) {
    Ok(value) => value
    Err(msg) => return Err(msg)
  }
  return parse_response(raw, http_method~)
}
