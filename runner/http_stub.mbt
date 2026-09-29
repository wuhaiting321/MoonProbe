/// MoonProbe - runner
///
/// Fallback transport for every backend other than `js`.
///
/// The MoonBit standard library ships no HTTP client, and only the `js` target
/// (running on Node.js) can reach one through its host. On the remaining
/// backends the runner states that limitation explicitly instead of pretending
/// the request succeeded, which keeps the parser and assertion layers testable
/// on `wasm-gc`.

#cfg(not(target="js"))
fn send(
  verb : String,
  url : String,
  headers : String,
  body : String,
  timeout_ms : Int
) -> Result[(Int, String), String] {
  ignore((verb, url, headers, body, timeout_ms))
  return Err(
    "no http transport on this backend: build MoonProbe for the `js` target (Node.js) to send real requests",
  )
}