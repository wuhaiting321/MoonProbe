/// MoonProbe - runner
///
/// Platform transport for the `js` backend.
///
/// A MoonBit `js` build has neither a standard HTTP client nor a synchronous
/// socket API, so the request is delegated to the host's `curl` binary through
/// Node.js `child_process`. The FFI boundary only exchanges strings and
/// integers, so no `js`-specific type leaks into the rest of the runner; every
/// other backend gets `http_stub.mbt` instead.

#cfg(target="js")
extern "js" fn host_http(
  verb : String,
  url : String,
  headers : String,
  body : String,
  timeout_secs : Int
) -> String =
  #| ((verb, url, headers, body, timeoutSecs) => {
  #|   const cp = require("child_process");
  #|   const args = [
  #|     "-sS",
  #|     "-X", verb,
  #|     "-m", String(timeoutSecs),
  #|     "-w", "\n%{http_code}",
  #|     "--url", url,
  #|   ];
  #|   if (headers) {
  #|     for (const line of headers.split("\n")) {
  #|       if (line) args.push("-H", line);
  #|     }
  #|   }
  #|   if (body) args.push("--data-binary", body);
  #|   try {
  #|     const out = cp.execFileSync("curl.exe", args, {
  #|       encoding: "utf8",
  #|       maxBuffer: 67108864,
  #|     });
  #|     const i = out.lastIndexOf("\n");
  #|     return "OK\n" + out.slice(i + 1) + "\n" + out.slice(0, i);
  #|   } catch (e) {
  #|     const detail = e && e.stderr ? String(e.stderr) : String((e && e.message) || e);
  #|     return "ERR\n" + detail.trim().replace(/\r?\n/g, " ");
  #|   }
  #| })

/// Split `s` at its first line break into `(first_line, rest)`.
#cfg(target="js")
fn split_first_line(s : String) -> (String, String) {
  match s.split_once("\n") {
    Some((head, rest)) => (head.to_owned(), rest.to_owned())
    None => (s, "")
  }
}

/// Parse a decimal integer, returning `None` for anything else.
#cfg(target="js")
fn parse_status(s : String) -> Option[Int] {
  if s.length() == 0 {
    return None
  }
  let mut acc = 0
  let mut i = 0
  while i < s.length() {
    let c = s.at(i).to_int()
    if c < 0x30 || c > 0x39 {
      return None
    }
    acc = acc * 10 + (c - 0x30)
    i = i + 1
  }
  return Some(acc)
}

/// Perform the request through `curl` and decode its reply into
/// `(status, body)`.
///
/// The reply is `OK\n<status>\n<body>` on success and `ERR\n<reason>` when the
/// transport itself failed. Only the success form is split further: a failure
/// reason is a sentence, not a set of fields, so it is reported whole.
#cfg(target="js")
fn send(
  verb : String,
  url : String,
  headers : String,
  body : String,
  timeout_ms : Int
) -> Result[(Int, String), String] {
  let raw = host_http(verb, url, headers, body, (timeout_ms + 999) / 1000)
  let (tag, rest) = split_first_line(raw)
  if tag == "OK" {
    let (status_text, response_body) = split_first_line(rest)
    match parse_status(status_text) {
      Some(status) => return Ok((status, response_body))
      None => return Err("transport reported a malformed status: \{status_text}")
    }
  }
  return Err("http request failed: \{rest}")
}