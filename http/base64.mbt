/// MoonProbe - http
///
/// Base64 decoding for the socket bridge.
///
/// The bridge hands the raw response back as base64 so that a binary body
/// survives the string boundary byte for byte. Decoding it here, rather than
/// pulling in a library, keeps the dependency surface of the protocol package
/// at exactly one thing: the standard UTF-8 codec it already needs.

///|
/// The six-bit value of a base64 alphabet character, or `None` for anything
/// outside the alphabet.
fn base64_value(code : Int) -> Int? {
  if code >= 0x41 && code <= 0x5a {
    // A-Z
    return Some(code - 0x41)
  }
  if code >= 0x61 && code <= 0x7a {
    // a-z
    return Some(code - 0x61 + 26)
  }
  if code >= 0x30 && code <= 0x39 {
    // 0-9
    return Some(code - 0x30 + 52)
  }
  if code == 0x2b {
    // +
    return Some(62)
  }
  if code == 0x2f {
    // /
    return Some(63)
  }
  return None
}

///|
/// Decode base64 text into bytes.
///
/// Padding is optional; whitespace is rejected rather than skipped, because the
/// only producer is the bridge, which never emits any. A malformed string is an
/// error instead of a best-effort decode, so a corrupted reply cannot turn into
/// a plausible-looking body.
pub fn decode_base64(text : String) -> Result[Bytes, String] {
  let out : Array[Byte] = []
  let n = text.length()
  let mut i = 0
  let mut acc = 0
  let mut bits = 0
  let mut padding = 0
  while i < n {
    let code = text.at(i).to_int()
    if code == 0x3d {
      padding = padding + 1
      if padding > 2 {
        return Err("invalid base64: too much padding")
      }
      i = i + 1
      continue
    }
    if padding > 0 {
      return Err("invalid base64: data after padding")
    }
    let value = match base64_value(code) {
      Some(value) => value
      None => return Err("invalid base64: unexpected character at offset \{i}")
    }
    acc = (acc << 6) | value
    bits = bits + 6
    if bits >= 8 {
      bits = bits - 8
      out.push(((acc >> bits) & 0xff).to_byte())
    }
    i = i + 1
  }
  // Leftover bits must be zero padding, never a partial byte.
  if bits >= 6 {
    return Err("invalid base64: a partial group")
  }
  if (acc & ((1 << bits) - 1)) != 0 {
    return Err("invalid base64: non-zero trailing bits")
  }
  return Ok(Bytes::from_array(out))
}
