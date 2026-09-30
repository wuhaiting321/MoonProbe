/// MoonProbe - lexer
///
/// The lexer turns raw `.probe` source text into a flat list of `LexedLine`
/// values. It is responsible for pure lexical concerns only:
///
///   - splitting the source into lines
///   - skipping blank lines, and stripping `#` comments wherever they appear
///   - computing each line's indentation level
///   - splitting each line into a `key` and an optional `value`
///   - decoding the escape sequences of a quoted value
///   - recognising a bare comparison such as `duration_ms < 500`
///
/// Semantic structure (which key opens a block, how nested values map to the
/// AST) is decided by the parser, not the lexer.

///|
/// A single meaningful line produced by the lexer.
pub struct LexedLine {
  /// Indentation width of this line (a tab counts as two columns).
  indent : Int
  /// The left-hand key, already trimmed.
  key : String
  /// Optional right-hand value (already unquoted), or `None` for a block
  /// header line such as `request:`.
  value : String?
  /// 1-based source line number for diagnostics.
  line_no : Int
}

///|
/// Lex the given `.probe` source into lexed lines.
///
/// Returns `Err(message)` if a non-empty line cannot be split into a
/// well-formed key (i.e. it contains no `:` separator).
pub fn lex(src : String) -> Result[Array[LexedLine], String] {
  let lines = split_lines(src)
  let out : Array[LexedLine] = []
  let mut line_no = 1
  for raw in lines {
    // Comments are removed first, so a comment-only line becomes blank and is
    // skipped just like an empty one — at any indentation, and without
    // disturbing the indentation of the code that precedes it on the line.
    let code = strip_comment(raw)
    if code.length() == 0 {
      line_no = line_no + 1
      continue
    }
    let (ws_len, indent) = measure_indent(code)
    let rest = code.view(start_offset=ws_len).to_owned()
    match split_key_value(rest) {
      Some((key, value)) => out.push({ indent, key, value, line_no, })
      None =>
        match split_comparison(rest) {
          Some((key, value)) =>
            out.push({ indent, key, value: Some(value), line_no, })
          None =>
            return Err("line \{line_no}: expected \"key:\", got \"\{rest}\"")
        }
    }
    line_no = line_no + 1
  }
  return Ok(out)
}

///|
/// Remove a `#` comment from `line` and trim the whitespace that introduced it,
/// leaving everything before the comment untouched.
///
/// A `#` opens a comment when both hold:
///
///   - it is not inside a single- or double-quoted string, and
///   - it is either the first character of the line or preceded by a space/tab.
///
/// The second rule is the convention every indentation-sensitive format (YAML,
/// hurl) follows, and it is what keeps a literal hash usable in an unquoted
/// value: `Authorization: Bearer a#b` and `url: https://x/a#frag` keep their
/// `#`, while `status: 200  # ok` loses the explanation. A value that must
/// *begin* with `#` can always be quoted — `contains: "#tag"`.
///
/// The quote state is tracked per line and starts fresh, so an unbalanced quote
/// inside a comment can never leak into the code part.
fn strip_comment(line : String) -> String {
  let n = line.length()
  let mut i = 0
  let mut single = false
  let mut double = false
  let mut cut = -1
  while i < n {
    let c = line.at(i).to_int()
    if !single && c == DOUBLE_QUOTE {
      double = !double
    } else if !double && c == SINGLE_QUOTE {
      single = !single
    } else if !single &&
      !double &&
      c == HASH &&
      (i == 0 || is_horizontal_space(line.at(i - 1).to_int())) {
      cut = i
      break
    }
    i = i + 1
  }
  let mut end = if cut >= 0 { cut } else { n }
  while end > 0 && is_horizontal_space(line.at(end - 1).to_int()) {
    end = end - 1
  }
  return line.view(start_offset=0, end_offset=end).to_owned()
}

///|
/// Measure the leading indentation of `line`.
///
/// Returns `(character_count, width)`, where `character_count` is the number of
/// leading whitespace characters — needed to slice the rest of the line — and
/// `width` is the visual indentation width, with a tab counting as two columns
/// so that tab-indented and space-indented sources nest identically.
fn measure_indent(line : String) -> (Int, Int) {
  let n = line.length()
  let mut i = 0
  let mut width = 0
  while i < n {
    let c = line.at(i).to_int()
    if c == 0x20 {
      width = width + 1
      i = i + 1
    } else if c == 0x09 {
      width = width + 2
      i = i + 1
    } else {
      break
    }
  }
  return (i, width)
}

///|
/// Split `line` at the first `:` (outside of quotes) into `(key, value)`.
/// The value is `None` if nothing meaningful follows the colon.
fn split_key_value(line : String) -> (String, String?)? {
  let n = line.length()
  let mut i = 0
  let mut single = false
  let mut double = false
  while i < n {
    let c = line.at(i).to_int()
    if !single && c == DOUBLE_QUOTE {
      double = !double
    } else if !double && c == SINGLE_QUOTE {
      single = !single
    } else if !single && !double && c == 0x3a {
      // Found the key/value separator `:`.
      let key = trim(line.view(start_offset=0, end_offset=i).to_owned())
      let raw_value = line.view(start_offset=i + 1).to_owned()
      let value = trim(raw_value)
      if value.length() == 0 {
        return Some((key, None))
      }
      return Some((key, Some(unquote(value))))
    }
    i = i + 1
  }
  // No `:` found: not a well-formed key line.
  return None
}

///|
/// Strip matching surrounding quotes from an already-trimmed value, decoding
/// the escape sequences of a quoted string on the way.
///
/// An unquoted value is returned verbatim: a bare `Authorization: Bearer a\b`
/// keeps its backslash, because only a quoted value opts into escaping. That
/// way a Windows path in an unquoted value never turns `\t` into a tab by
/// accident.
fn unquote(value : String) -> String {
  let n = value.length()
  if n >= 2 {
    let first = value.at(0).to_int()
    let last = value.at(n - 1).to_int()
    if (first == 0x22 && last == 0x22) || (first == 0x27 && last == 0x27) {
      let inner = value.view(start_offset=1, end_offset=n - 1).to_owned()
      return unescape(inner)
    }
  }
  return value
}

///|
/// Expand the escape sequences of a quoted `.probe` value.
///
/// `\n`, `\t`, `\r`, `\\`, `\"` and `\'` are understood; any other backslash is
/// kept as-is so that an unknown escape can never silently swallow a character.
fn unescape(text : String) -> String {
  if !text.contains_char('\\') {
    return text
  }
  let buf = StringBuilder()
  let n = text.length()
  let mut i = 0
  while i < n {
    let code = text.at(i).to_int()
    if code != BACKSLASH || i + 1 >= n {
      buf.write_char(code.to_char().unwrap())
      i = i + 1
      continue
    }
    let next = text.at(i + 1).to_int()
    if next == 0x6e {
      buf.write_char('\n')
    } else if next == 0x74 {
      buf.write_char('\t')
    } else if next == 0x72 {
      buf.write_char('\r')
    } else if next == BACKSLASH {
      buf.write_char('\\')
    } else if next == 0x22 {
      buf.write_char('"')
    } else if next == 0x27 {
      buf.write_char('\'')
    } else {
      buf.write_char('\\')
      buf.write_char(text.at(i + 1).to_int().to_char().unwrap())
    }
    i = i + 2
  }
  return buf.to_string()
}

///|
/// The code point of the backslash character.
const BACKSLASH : Int = 0x5c

///|
/// The code point of `#`, which opens a comment.
const HASH : Int = 0x23

///|
/// The code point of the double quote, which starts a string value.
const DOUBLE_QUOTE : Int = 0x22

///|
/// The code point of the single quote, which starts a string value.
const SINGLE_QUOTE : Int = 0x27

///|
/// Split a bare comparison expression such as `duration_ms < 500` into
/// `("duration_ms", "< 500")`.
///
/// A budget assertion reads far better without the `:` of a key/value pair, so
/// the shape `<name> <operator> <number>` is recognised as a lexical form of its
/// own. Anything else that lacks a colon is still a syntax error.
fn split_comparison(line : String) -> (String, String)? {
  let trimmed = trim(line)
  let n = trimmed.length()
  let mut i = 0
  while i < n && !is_horizontal_space(trimmed.at(i).to_int()) {
    i = i + 1
  }
  if i == 0 || i == n {
    return None
  }
  let key = trimmed.view(start_offset=0, end_offset=i).to_owned()
  let rest = trim(trimmed.view(start_offset=i).to_owned())
  if !starts_with_operator(rest) {
    return None
  }
  return Some((key, rest))
}

///|
/// Whether `code` is a space or a tab.
fn is_horizontal_space(code : Int) -> Bool {
  return code == 0x20 || code == 0x09
}

///|
/// Whether `text` begins with one of the comparison operators a `.probe` budget
/// assertion may use.
fn starts_with_operator(text : String) -> Bool {
  let n = text.length()
  if n == 0 {
    return false
  }
  let first = text.at(0).to_int()
  if first == 0x3c || first == 0x3e {
    return true
  }
  if n < 2 {
    return false
  }
  let second = text.at(1).to_int()
  if first == 0x21 {
    // `!=`
    return second == 0x3d
  }
  if first == 0x3d {
    // A lone `=` is a plain text value; only `==` is an operator.
    return second == 0x3d
  }
  return false
}

///|
/// Trim leading/trailing whitespace from `s`.
fn trim(s : String) -> String {
  return s.trim().to_owned()
}

///|
/// Split a source string into lines, tolerating both LF and CRLF endings.
fn split_lines(src : String) -> Array[String] {
  let lines : Array[String] = []
  let n = src.length()
  let mut start = 0
  let mut i = 0
  while i < n {
    if src.at(i).to_int() == 0x0a {
      let mut end = i
      if end > start && src.at(end - 1).to_int() == 0x0d {
        end = end - 1
      }
      lines.push(src.view(start_offset=start, end_offset=end).to_owned())
      start = i + 1
    }
    i = i + 1
  }
  if start < n {
    lines.push(src.view(start_offset=start, end_offset=n).to_owned())
  }
  return lines
}
