///|
/// MoonProbe - http
///
/// The `js` host binding: the one place where the protocol stack meets a real
/// socket.
///
/// MoonBit's core library ships no socket API, so the host has to provide the
/// byte pipe. What it provides is deliberately minimal -- open a TCP (or TLS)
/// connection, write the request bytes, read bytes until the peer closes -- and
/// nothing else. No HTTP semantics cross this boundary: status lines, chunk
/// framing, interim responses and header parsing all stay in `parser.mbt`, so
/// the same code is exercised by the `wasm-gc` tests.
///
/// The pipe is a child Node process running a short inline script, launched with
/// `process.execPath` rather than a system tool. That is what removes the old
/// dependency on `curl.exe`: there is no binary to find, and no difference
/// between macOS, Linux and Windows. The response is base64 so a binary body
/// survives the string boundary byte for byte.
#cfg(target="js")
extern "js" fn host_exchange(
  host : String,
  port : Int,
  tls : Bool,
  payload : String,
  timeout_ms : Int,
) -> String =
  #| ((host, port, tls, payload, timeoutMs) => {
  #|   const cp = require("child_process");
  #|   const source = [
  #|     'const net = require("net");',
  #|     'const tls = require("tls");',
  #|     'const host = process.argv[1];',
  #|     'const port = Number(process.argv[2]);',
  #|     'const mode = process.argv[3];',
  #|     'const timeoutMs = Number(process.argv[4]);',
  #|     'const chunks = [];',
  #|     'let total = 0;',
  #|     'process.stdin.on("data", (chunk) => { chunks.push(chunk); total += chunk.length; });',
  #|     'process.stdin.on("end", () => {',
  #|     '  const payload = Buffer.concat(chunks, total);',
  #|     '  const socket = mode === "tls"',
  #|     '    ? tls.connect({ host: host, port: port, servername: host }, () => socket.write(payload))',
  #|     '    : net.connect({ host: host, port: port }, () => socket.write(payload));',
  #|     '  const out = [];',
  #|     '  let finished = false;',
  #|     '  const finish = () => {',
  #|     '    if (finished) return;',
  #|     '    finished = true;',
  #|     '    process.stdout.write(Buffer.concat(out).toString("base64"));',
  #|     '  };',
  #|     '  socket.setTimeout(timeoutMs, () => {',
  #|     '    process.stderr.write("the connection was idle for " + timeoutMs + " ms");',
  #|     '    socket.destroy();',
  #|     '    process.exit(2);',
  #|     '  });',
  #|     '  socket.on("data", (chunk) => out.push(chunk));',
  #|     '  socket.on("end", finish);',
  #|     '  socket.on("close", finish);',
  #|     '  socket.on("error", (error) => {',
  #|     '    process.stderr.write(String((error && error.message) || error));',
  #|     '    process.exit(1);',
  #|     '  });',
  #|     '});',
  #|   ].join("\n");
  #|   try {
  #|     const result = cp.spawnSync(
  #|       process.execPath,
  #|       ["-e", source, host, String(port), tls ? "tls" : "tcp", String(timeoutMs)],
  #|       {
  #|         input: Buffer.from(payload, "utf8"),
  #|         encoding: "buffer",
  #|         maxBuffer: 67108864,
  #|         timeout: timeoutMs + 5000,
  #|       },
  #|     );
  #|     if (result.error) {
  #|       return "ERR\n" + String(result.error.message || result.error);
  #|     }
  #|     if (result.status !== 0) {
  #|       const detail = result.stderr && result.stderr.length
  #|         ? result.stderr.toString("utf8")
  #|         : "the socket bridge exited with code " + result.status;
  #|       return "ERR\n" + detail.trim().replace(/\r?\n/g, " ");
  #|     }
  #|     return "OK\n" + result.stdout.toString("base64");
  #|   } catch (error) {
  #|     return "ERR\n" + String((error && error.message) || error);
  #|   }
  #| })

///|
/// Send one request over a real socket.
///
/// The wire request is rendered exactly as a scripted test would render it, so
/// the bytes the protocol layer decides on are the bytes that go out.
#cfg(target="js")
pub fn send_platform(
  http_method : String,
  raw_url : String,
  header_block : String,
  body : String?,
  timeout_ms : Int,
) -> Result[Response, String] {
  let url = match parse_url(raw_url) {
    Ok(value) => value
    Err(msg) => return Err(msg)
  }
  let wire = render_request(http_method, url, header_block, body)
  let reply = host_exchange(url.host, url.port, url.is_tls(), wire, timeout_ms)
  let rest = match reply.split_once("\n") {
    Some((tag, rest)) =>
      if tag == "OK" {
        rest
      } else {
        return Err("http request failed: \{rest}")
      }
    None => return Err("the socket bridge returned a malformed reply")
  }
  let raw = match decode_base64(rest.to_owned()) {
    Ok(value) => value
    Err(msg) =>
      return Err("the socket bridge returned unreadable bytes: \{msg}")
  }
  return parse_response(raw, http_method~)
}
