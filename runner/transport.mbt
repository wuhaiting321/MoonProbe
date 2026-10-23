///|
/// MoonProbe - runner
///
/// The platform transport.
///
/// There is no `curl` here any more, and no per-target copy of this function:
/// the runner hands the request to the `http` package, which owns both the
/// protocol and the socket. On a backend without a socket the package's stub
/// answers with an explicit error, so this one function compiles and behaves
/// consistently everywhere.
///
/// `curl` used to be the transport, which pinned the runner to `curl.exe` on
/// Windows and let the tool reinterpret the request: a body starting with `@`
/// became a file upload, a fragment could swallow the query string, and a
/// `100 Continue` reply could leak its header block into the body. None of those
/// decisions are the tool's to make now -- the bytes are rendered by
/// `render_request` and parsed by `parse_response`.
fn send(
  verb : String,
  url : String,
  headers : String,
  body : String,
  timeout_ms : Int32,
) -> Result[(Int32, Array[(String, String)], String), String] {
  let declared = if body.length() == 0 { None } else { Some(body) }
  match @http.send_platform(verb, url, headers, declared, timeout_ms) {
    Ok(response) => Ok((response.status, response.headers, response.body))
    Err(msg) => Err(msg)
  }
}
