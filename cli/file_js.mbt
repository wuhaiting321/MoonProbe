/// MoonProbe - cli
///
/// Reading a `.probe` suite from disk.
///
/// The MoonBit core library ships no file system API, so the `js` backend — the
/// one that runs on Node.js — reaches the host through `fs.readFileSync`. Every
/// other backend reports that reading is unsupported rather than failing with an
/// obscure error.

#cfg(target="js")
extern "js" fn host_read_file(path : String) -> String =
  #| ((path) => {
  #|   const fs = require("fs");
  #|   try {
  #|     return "OK\n" + fs.readFileSync(path, "utf8");
  #|   } catch (e) {
  #|     return "ERR\n" + String((e && e.message) || e);
  #|   }
  #| })

/// Read the `.probe` suite at `path`.
///
/// The reply from the host is `OK\n<contents>` on success and `ERR\n<reason>`
/// when the file cannot be read, so that a missing file becomes an ordinary
/// `Err` instead of a host exception crossing the FFI boundary.
#cfg(target="js")
fn read_source(path : String) -> Result[String, String] {
  let raw = host_read_file(path)
  match raw.split_once("\n") {
    Some((tag, body)) =>
      if tag == "OK" {
        Ok(body.to_owned())
      } else {
        Err("cannot read \"\{path}\": \{body}")
      }
    None => Err("cannot read \"\{path}\": malformed reply from the host")
  }
}

/// Reading a suite needs a file system, which only the `js` target can reach
/// through Node.js.
#cfg(not(target="js"))
fn read_source(path : String) -> Result[String, String] {
  ignore(path)
  return Err(
    "reading .probe files needs the `js` target (Node.js): build with --target js",
  )
}