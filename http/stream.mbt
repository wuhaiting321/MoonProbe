/// MoonProbe - http
///
/// A cursor over the bytes a connection returned.
///
/// The parser never assumes the whole response arrived in one piece: it reads
/// through this cursor, which reports a truncated message as `Err` instead of
/// indexing past the end. That is what makes the same code usable both on a
/// buffered test fixture and on a socket that closed halfway through a body.

///|
/// A read position over a byte buffer.
pub struct Cursor {
  data : Bytes
  mut pos : Int
}

///|
/// Start reading at the beginning of `data`.
pub fn Cursor::new(data : Bytes) -> Cursor {
  return { data, pos: 0, }
}

///|
/// How many bytes are left to read.
pub fn Cursor::remaining(self : Cursor) -> Int {
  return self.data.length() - self.pos
}

///|
/// Whether every byte has been consumed.
pub fn Cursor::at_end(self : Cursor) -> Bool {
  return self.pos >= self.data.length()
}

///|
/// Read one line and consume its terminator.
///
/// Both `CRLF` and a bare `LF` are accepted on input, because a lenient reader
/// is what lets the parser survive a server that got the line ending wrong.
/// The final line of a message may end at EOF without any terminator at all.
fn Cursor::read_line(self : Cursor) -> Result[BytesView, String] {
  let n = self.data.length()
  if self.pos >= n {
    return Err("unexpected end of message: a line was expected")
  }
  let mut i = self.pos
  while i < n {
    if self.data.at(i).to_int() == 0x0a {
      let mut end = i
      if end > self.pos && self.data.at(end - 1).to_int() == 0x0d {
        end = end - 1
      }
      let line = self.data.exact_view(start=self.pos, end~)
      self.pos = i + 1
      return Ok(line)
    }
    i = i + 1
  }
  let line = self.data.exact_view(start=self.pos, end=n)
  self.pos = n
  return Ok(line)
}

///|
/// Read exactly `count` bytes, or fail when the message ends early.
fn Cursor::read_exact(self : Cursor, count : Int) -> Result[BytesView, String] {
  if count < 0 {
    return Err("internal error: negative read length")
  }
  if self.pos + count > self.data.length() {
    return Err(
      "the message ended early: \{count} bytes were announced, \{self.remaining()} were available",
    )
  }
  let view = self.data.exact_view(start=self.pos, end=self.pos + count)
  self.pos = self.pos + count
  return Ok(view)
}

///|
/// Every byte left, from the current position to the end.
fn Cursor::rest(self : Cursor) -> BytesView {
  return self.data.exact_view(start=self.pos, end=self.data.length())
}

///|
/// Copy a view into a growable byte array.
fn collect(view : BytesView) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut i = 0
  while i < view.length() {
    out.push(view.at(i))
    i = i + 1
  }
  return out
}

///|
/// Decode a slice of the message as text.
///
/// Headers are ASCII by construction; a body is decoded as UTF-8 and falls back
/// to replacement characters, so a binary payload cannot abort the run.
fn text_of(view : BytesView) -> String {
  return @utf8.decode_lossy(view)
}

///|
/// Whether `text` has `prefix` as its ASCII-case-insensitive prefix.
fn starts_with_ci(text : String, prefix : String) -> Bool {
  if text.length() < prefix.length() {
    return false
  }
  let mut i = 0
  while i < prefix.length() {
    let a = text.at(i).to_int()
    let b = prefix.at(i).to_int()
    let al = if a >= 0x41 && a <= 0x5a { a + 0x20 } else { a }
    let bl = if b >= 0x41 && b <= 0x5a { b + 0x20 } else { b }
    if al != bl {
      return false
    }
    i = i + 1
  }
  return true
}

///|
/// Whether `text` equals `other`, ignoring ASCII case.
fn equals_ci(text : String, other : String) -> Bool {
  if text.length() != other.length() {
    return false
  }
  let mut i = 0
  while i < text.length() {
    let a = text.at(i).to_int()
    let b = other.at(i).to_int()
    let al = if a >= 0x41 && a <= 0x5a { a + 0x20 } else { a }
    let bl = if b >= 0x41 && b <= 0x5a { b + 0x20 } else { b }
    if al != bl {
      return false
    }
    i = i + 1
  }
  return true
}
