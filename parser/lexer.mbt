/// MoonProbe - lexer
///
/// The lexer turns raw `.probe` source text into a flat list of `LexedLine`
/// values. It is responsible for pure lexical concerns only:
///
///   - splitting the source into lines
///   - skipping blank lines and `#` comments
///   - computing each line's indentation level
///   - splitting each line into a `key` and an optional `value`
///
/// Semantic structure (which key opens a block, how nested values map to the
/// AST) is decided by the parser, not the lexer.

/// A single meaningful line produced by the lexer.
pub struct LexedLine {
  /// Indentation width of this line (a tab counts as two columns).
  indent : Int
  /// The left-hand key, already trimmed.
  key : String
  /// Optional right-hand value (already unquoted), or `None` for a block
  /// header line such as `request:`.
  value : Option[String]
  /// 1-based source line number for diagnostics.
  line_no : Int
}

/// Lex the given `.probe` source into lexed lines.
///
/// Returns `Err(message)` if a non-empty line cannot be split into a
/// well-formed key (i.e. it contains no `:` separator).
pub fn lex(src : String) -> Result[Array[LexedLine], String] {
  let lines = split_lines(src)
  let out : Array[LexedLine] = []
  let mut line_no = 1
  for raw in lines {
    let trimmed = raw.trim().to_owned()
    if trimmed.length() == 0 {
      line_no = line_no + 1
      continue
    }
    if trimmed.has_prefix("#") {
      line_no = line_no + 1
      continue
    }
    let (ws_len, indent) = measure_indent(raw)
    let rest = raw.view(start_offset=ws_len).to_owned()
    match split_key_value(rest) {
      Some((key, value)) => {
        out.push({ indent, key, value, line_no })
      }
      None => {
        return Err("line \{line_no}: expected \"key:\", got \"\{rest}\"")
      }
    }
    line_no = line_no + 1
  }
  return Ok(out)
}

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

/// Split `line` at the first `:` (outside of quotes) into `(key, value)`.
/// The value is `None` if nothing meaningful follows the colon.
fn split_key_value(line : String) -> Option[(String, Option[String])] {
  let n = line.length()
  let mut i = 0
  let mut single = false
  let mut double = false
  while i < n {
    let c = line.at(i).to_int()
    if (!single) && c == 0x22 {
      double = !double
    } else if (!double) && c == 0x27 {
      single = !single
    } else if (!single) && (!double) && c == 0x3a {
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

/// Strip matching surrounding quotes from an already-trimmed value.
fn unquote(value : String) -> String {
  let n = value.length()
  if n >= 2 {
    let first = value.at(0).to_int()
    let last = value.at(n - 1).to_int()
    if (first == 0x22 && last == 0x22) || (first == 0x27 && last == 0x27) {
      return value.view(start_offset=1, end_offset=n - 1).to_owned()
    }
  }
  return value
}

/// Trim leading/trailing whitespace from `s`.
fn trim(s : String) -> String {
  return s.trim().to_owned()
}

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