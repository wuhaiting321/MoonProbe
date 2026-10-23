/// MoonProbe - http
///
/// The response side of HTTP/1.1: status line, header block, and body framing.
///
/// Three framing rules are implemented, because a server picks one of them:
///
///   - `Transfer-Encoding: chunked`, with chunk extensions and trailers,
///   - `Content-Length`, which fixes the body length exactly,
///   - connection close, which leaves the body delimited by EOF.
///
/// Interim `1xx` responses are skipped rather than mistaken for the body. That
/// is the bug the old `curl`-based transport could not fix from the outside: a
/// `100 Continue` has its own header block, and a parser that treats the first
/// status line as final reads that block as the payload.
///
/// Statuses that forbid a body (`204`, `304`, and every response to `HEAD`) are
/// honoured even when the server still sends a `Content-Length` for them.

///|
/// A parsed HTTP response.
pub struct Response {
  /// Final status code, after any interim `1xx` responses were skipped.
  status : Int32
  /// Reason phrase as sent by the server, possibly empty.
  reason : String
  /// Header fields in arrival order, with names as the server wrote them.
  headers : Array[(String, String)]
  /// Body decoded as UTF-8.
  body : String
  /// How many interim `1xx` responses preceded the final one.
  interim : Int32
}

///|
/// Split `HTTP/1.1 200 OK` into its status code and reason phrase.
fn parse_status_line(text : String) -> Result[(Int32, String), String] {
  if !starts_with_ci(text, "HTTP/") {
    return Err("malformed status line \"\{text}\": expected HTTP/<version>")
  }
  let space = match find_sub(text, " ", 0) {
    Some(i) => i
    None => return Err("malformed status line \"\{text}\": no status code")
  }
  if space + 4 > text.length() {
    return Err("malformed status line \"\{text}\": no status code")
  }
  let code_text = text
    .view(start_offset=space + 1, end_offset=space + 4)
    .to_owned()
  if code_text.length() != 3 {
    return Err(
      "malformed status line \"\{text}\": the status code must have three digits",
    )
  }
  let mut code = 0
  let mut i = 0
  while i < 3 {
    let c = code_text.at(i).to_int()
    if c < 0x30 || c > 0x39 {
      return Err(
        "malformed status line \"\{text}\": the status code must have three digits",
      )
    }
    code = code * 10 + (c - 0x30)
    i = i + 1
  }
  let reason = if space + 4 < text.length() {
    text.view(start_offset=space + 4).to_owned().trim().to_owned()
  } else {
    ""
  }
  return Ok((code, reason))
}

///|
/// Read the header block that follows a status line, up to the empty line.
///
/// A line starting with a space or tab continues the previous value (the
/// obsolete line folding RFC 9110 still allows a server to emit); it is folded
/// into one value with a single space, so header consumers never see the
/// physical layout.
fn parse_headers(cursor : Cursor) -> Result[Array[(String, String)], String] {
  let out : Array[(String, String)] = []
  let mut done = false
  while !done {
    let line = match cursor.read_line() {
      Ok(value) => value
      Err(msg) => return Err(msg)
    }
    if line.length() == 0 {
      done = true
      continue
    }
    let first = line.at(0).to_int()
    if (first == 0x20 || first == 0x09) && out.length() > 0 {
      let (name, value) = out[out.length() - 1]
      let continuation = text_of(line).trim().to_owned()
      out[out.length() - 1] = (name, "\{value} \{continuation}")
      continue
    }
    let text = text_of(line)
    let colon = match find_sub(text, ":", 0) {
      Some(i) => i
      None =>
        return Err("malformed header line \"\{text}\": expected name: value")
    }
    let name = text
      .view(start_offset=0, end_offset=colon)
      .to_owned()
      .trim()
      .to_owned()
    let value = text.view(start_offset=colon + 1).to_owned().trim().to_owned()
    if name.length() == 0 {
      return Err("malformed header line \"\{text}\": empty field name")
    }
    out.push((name, value))
  }
  return Ok(out)
}

///|
/// All values of the header called `name`, matched case-insensitively.
fn header_values(
  headers : Array[(String, String)],
  name : String,
) -> Array[String] {
  let out : Array[String] = []
  for pair in headers {
    if equals_ci(pair.0, name) {
      out.push(pair.1)
    }
  }
  return out
}

///|
/// Whether the response announces a chunked body.
fn is_chunked(headers : Array[(String, String)]) -> Bool {
  for value in header_values(headers, "Transfer-Encoding") {
    // The coding list is comma separated; the last coding wins, but any
    // occurrence of `chunked` means the body is chunk framed.
    let lower = ascii_lower(value)
    if contains_token(lower, "chunked") {
      return true
    }
  }
  return false
}

///|
/// Whether `list` contains `token` as a comma-separated element.
fn contains_token(list : String, token : String) -> Bool {
  for part in list.split(",") {
    let item = part.trim().to_owned()
    // A coding may carry parameters: `gzip; q=1`.
    let name = match find_sub(item, ";", 0) {
      Some(i) =>
        item.view(start_offset=0, end_offset=i).to_owned().trim().to_owned()
      None => item
    }
    if name == token {
      return true
    }
  }
  return false
}

///|
/// The declared body length, if exactly one valid `Content-Length` exists.
fn content_length(headers : Array[(String, String)]) -> Result[Int32?, String] {
  let values = header_values(headers, "Content-Length")
  if values.length() == 0 {
    return Ok(None)
  }
  let mut parsed : Int32? = None
  for raw in values {
    let text = raw.trim().to_owned()
    if text.length() == 0 {
      return Err("invalid Content-Length: empty value")
    }
    let mut value = 0
    let mut i = 0
    while i < text.length() {
      let c = text.at(i).to_int()
      if c < 0x30 || c > 0x39 {
        return Err("invalid Content-Length \"\{text}\": expected digits")
      }
      value = value * 10 + (c - 0x30)
      if value > 2147483647 {
        return Err("invalid Content-Length \"\{text}\": too large")
      }
      i = i + 1
    }
    match parsed {
      Some(previous) =>
        if previous != value {
          return Err(
            "conflicting Content-Length values: \{previous} and \{value}",
          )
        }
      None => parsed = Some(value)
    }
  }
  return Ok(parsed)
}

///|
/// Parse a hexadecimal chunk size.
fn parse_hex(text : String) -> Result[Int32, String] {
  if text.length() == 0 {
    return Err("malformed chunk: the size is empty")
  }
  let mut value = 0
  let mut i = 0
  while i < text.length() {
    let c = text.at(i).to_int()
    let digit = if c >= 0x30 && c <= 0x39 {
      c - 0x30
    } else if c >= 0x61 && c <= 0x66 {
      c - 0x61 + 10
    } else if c >= 0x41 && c <= 0x46 {
      c - 0x41 + 10
    } else {
      return Err(
        "malformed chunk size \"\{text}\": expected hexadecimal digits",
      )
    }
    if value > 134217727 {
      return Err("malformed chunk size \"\{text}\": too large")
    }
    value = value * 16 + digit
    i = i + 1
  }
  return Ok(value)
}

///|
/// Decode a chunked body into its payload bytes.
///
/// Chunk extensions (`;name=value`) are ignored, and the trailer section after
/// the terminating zero chunk is read and discarded: a trailer may only carry
/// metadata, never a change to the body already read.
fn decode_chunked(cursor : Cursor) -> Result[Array[Byte], String] {
  let out : Array[Byte] = []
  let mut done = false
  while !done {
    let line = match cursor.read_line() {
      Ok(value) => value
      Err(msg) => return Err(msg)
    }
    let text = text_of(line)
    let size_text = match find_sub(text, ";", 0) {
      Some(i) => text.view(start_offset=0, end_offset=i).to_owned()
      None => text
    }
    let size = match parse_hex(size_text.trim().to_owned()) {
      Ok(value) => value
      Err(msg) => return Err(msg)
    }
    if size == 0 {
      let mut trailers_done = false
      while !trailers_done {
        let trailer = match cursor.read_line() {
          Ok(value) => value
          Err(msg) => return Err(msg)
        }
        if trailer.length() == 0 {
          trailers_done = true
        }
      }
      done = true
      continue
    }
    let chunk = match cursor.read_exact(size) {
      Ok(value) => value
      Err(msg) => return Err(msg)
    }
    let mut i = 0
    while i < chunk.length() {
      out.push(chunk.at(i))
      i = i + 1
    }
    let crlf = match cursor.read_exact(2) {
      Ok(value) => value
      Err(msg) => return Err(msg)
    }
    if crlf.at(0).to_int() != 0x0d || crlf.at(1).to_int() != 0x0a {
      return Err("malformed chunk: the payload is not followed by CRLF")
    }
  }
  return Ok(out)
}

///|
/// Parse a complete HTTP/1.1 response from the bytes a connection returned.
///
/// `http_method` is needed only to honour the one framing rule that is stated
/// by the request rather than the response: a reply to `HEAD` never has a body,
/// even when it carries a `Content-Length` describing what a `GET` would return.
pub fn parse_response(
  raw : Bytes,
  http_method~ : String = "GET",
) -> Result[Response, String] {
  let cursor = Cursor::new(raw)
  let mut status = 0
  let mut reason = ""
  let mut headers : Array[(String, String)] = []
  let mut interim = 0
  let mut done = false
  while !done {
    let status_line = match cursor.read_line() {
      Ok(value) => value
      Err(msg) => return Err(msg)
    }
    let (code, phrase) = match parse_status_line(text_of(status_line)) {
      Ok(value) => value
      Err(msg) => return Err(msg)
    }
    headers = match parse_headers(cursor) {
      Ok(value) => value
      Err(msg) => return Err(msg)
    }
    // A final response is anything outside `1xx`; `101 Switching Protocols` is
    // an upgrade, not an interim step toward another response, so it is final.
    if code >= 100 && code <= 199 && code != 101 {
      interim = interim + 1
      continue
    }
    status = code
    reason = phrase
    done = true
  }
  let body : Array[Byte] = if equals_ci(http_method, "HEAD") ||
    status == 204 ||
    status == 304 {
    []
  } else if is_chunked(headers) {
    match decode_chunked(cursor) {
      Ok(value) => value
      Err(msg) => return Err(msg)
    }
  } else {
    let declared = match content_length(headers) {
      Ok(value) => value
      Err(msg) => return Err(msg)
    }
    match declared {
      Some(length) =>
        match cursor.read_exact(length) {
          Ok(value) => collect(value)
          Err(msg) => return Err(msg)
        }
      None => collect(cursor.rest())
    }
  }
  return Ok({
    status,
    reason,
    headers,
    body: @utf8.decode_lossy(Bytes::from_array(body)),
    interim,
  })
}
