/// MoonProbe - http
///
/// The non-`js` fallback.
///
/// Any other backend can parse, serialize and assert -- that is what the
/// `wasm-gc` test run exercises -- but none of them can open a socket through
/// the core library, so the platform send reports that fact instead of
/// pretending a request happened.

///|
/// Report that this backend has no socket.
#cfg(not(target="js"))
pub fn send_platform(
  http_method : String,
  raw_url : String,
  header_block : String,
  body : String?,
  timeout_ms : Int32,
) -> Result[Response, String] {
  ignore((http_method, raw_url, header_block, body, timeout_ms))
  return Err(
    "no http transport on this backend: build MoonProbe for the `js` target (Node.js) to send real requests",
  )
}
