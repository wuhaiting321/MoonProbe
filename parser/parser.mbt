/// MoonProbe - parser
///
/// The parser walks the lexed lines and assembles them into an AST `Suite`.
/// It understands the declarative `.probe` grammar:
///
/// ```text
/// name: "label of the case"
/// request:            # --- request block ---
///   method: GET
///   url: "..."
///   headers:
///     Authorization: "Bearer x"
///   query:
///     page: 1
///   body: '{"active": true}'
/// expect:             # --- assertion block ---
///   status: 200
///   json:
///     code: 0
///     data.count: 3
///   set: token = data.access_token   # --- variable extraction ---
/// ```
///
/// Higher-level concerns (executing the requests, running assertions) live in
/// other packages; the parser only produces data.

/// Parse `.probe` source text into an AST suite.
pub fn parse(src : String) -> Result[Suite, String] {
  let lines = match lex(src) {
    Ok(v) => v
    Err(msg) => return Err(msg)
  }
  if lines.length() == 0 {
    return Err("empty suite: no test case found")
  }
  let cases : Array[Case] = []
  let mut i = 0
  while i < lines.length() {
    let line = lines[i]
    if line.indent != 0 {
      return Err("line \{line.line_no}: unexpected indentation at top level")
    }
    if line.key != "name" {
      return Err(
        "line \{line.line_no}: unexpected top-level key \"\{line.key}\""
      )
    }
    let name = line.value.unwrap_or("")
    if name.length() == 0 {
      return Err("line \{line.line_no}: case name must not be empty")
    }
    // Advance past the name line and collect request/expect blocks until the
    // next `name:` line at the same depth.
    i = i + 1
    let (case_result, next) = parse_case(name, lines, i, 0)
    cases.push(match case_result {
      Ok(c) => c
      Err(msg) => return Err(msg)
    })
    i = next
  }
  if cases.length() == 0 {
    return Err("no test case defined")
  }
  return Ok({ cases, })
}

/// Indentation of a block's direct children: the indentation of the first line
/// deeper than `parent_indent`, scanning from `start`.
///
/// Returns `-1` when the block has no body. Deriving the child indentation from
/// the source instead of assuming a fixed step keeps the parser independent of
/// whether the author indents with two, four or more spaces.
fn child_indent_of(
  lines : Array[LexedLine],
  start : Int,
  parent_indent : Int
) -> Int {
  if start >= lines.length() {
    return -1
  }
  let indent = lines[start].indent
  if indent <= parent_indent {
    return -1
  }
  return indent
}

/// Parse the request + expect blocks belonging to one case.
fn parse_case(
  names : String,
  lines : Array[LexedLine],
  start : Int,
  parent_indent : Int
) -> (Result[Case, String], Int) {
  let mut request : Option[Request] = None
  let mut expect : Option[Expect] = None
  let mut i = start
  while i < lines.length() {
    let line = lines[i]
    if line.indent < parent_indent {
      break
    }
    if line.indent == parent_indent {
      // A sibling top-level key.
      if line.key == "name" {
        break
      } else if line.key == "request" {
        let (r, ni) = parse_request(lines, i + 1, parent_indent)
        request = match r {
          Ok(val) => Some(val)
          Err(msg) => return (Err(msg), i)
        }
        i = ni
      } else if line.key == "expect" {
        let (e, ni) = parse_expect(lines, i + 1, parent_indent)
        expect = match e {
          Ok(val) => Some(val)
          Err(msg) => return (Err(msg), i)
        }
        i = ni
      } else {
        return (Err("line \{line.line_no}: unknown case key \"\{line.key}\""), i + 1)
      }
    } else {
      // Deeper than the case's direct children: unsupported in this grammar.
      return (Err("line \{line.line_no}: unexpected nesting"), i + 1)
    }
  }
  let req = match request {
    Some(r) => r
    None => return (Err("case \"\{names}\": missing request block"), i)
  }
  let exp = match expect {
    Some(e) => e
    None => return (Err("case \"\{names}\": missing expect block"), i)
  }
  return (Ok({ name: names, request: req, expect: exp }), i)
}

/// Parse a `request:` block. `parent_indent` is the indentation of the
/// `request:` line itself; its children live one level deeper.
fn parse_request(
  lines : Array[LexedLine],
  start : Int,
  parent_indent : Int
) -> (Result[Request, String], Int) {
  let mut http_method = "GET"
  let mut url : Option[String] = None
  let mut body : Option[String] = None
  let mut headers : Array[Pair] = []
  let mut query : Array[Pair] = []
  let field_indent = child_indent_of(lines, start, parent_indent)
  let mut i = start
  while i < lines.length() {
    let line = lines[i]
    if line.indent <= parent_indent {
      break
    }
    if line.indent == field_indent {
      match line.key {
        "method" => {
          http_method = line.value.unwrap_or("GET")
          if http_method.length() == 0 {
            http_method = "GET"
          }
        }
        "url" => {
          url = match line.value {
            Some(v) => Some(v)
            None => return (Err("line \{line.line_no}: url requires a value"), i)
          }
        }
        "body" => {
          body = line.value
        }
        "headers" => {
          let (pairs, ni) = parse_pairs(lines, i + 1, line.indent)
          headers = pairs
          i = ni
          continue
        }
        "query" => {
          let (pairs, ni) = parse_pairs(lines, i + 1, line.indent)
          query = pairs
          i = ni
          continue
        }
        _ => {
          return (
            Err("line \{line.line_no}: unknown request field \"\{line.key}\""),
            i + 1,
          )
        }
      }
      i = i + 1
    } else {
      i = i + 1
    }
  }
  let u = match url {
    Some(v) => v
    None => return (Err("request: missing url"), i)
  }
  return (Ok({ http_method: http_method, url: u, headers, query, body }), i)
}

/// Parse an `expect:` block.
fn parse_expect(
  lines : Array[LexedLine],
  start : Int,
  parent_indent : Int
) -> (Result[Expect, String], Int) {
  let mut status : Option[Int] = None
  let mut checks : Array[JsonCheck] = []
  let sets : Array[SetSpec] = []
  let field_indent = child_indent_of(lines, start, parent_indent)
  let mut i = start
  while i < lines.length() {
    let line = lines[i]
    if line.indent <= parent_indent {
      break
    }
    if line.indent == field_indent {
      match line.key {
        "status" => {
          let v = line.value.unwrap_or("")
          status = match parse_int(v) {
            Some(n) => Some(n)
            None => return (Err("line \{line.line_no}: invalid status \"\{v}\""), i)
          }
        }
        "json" => {
          let (pairs, ni) = parse_pairs(lines, i + 1, line.indent)
          let chk : Array[JsonCheck] = []
          for p in pairs {
            chk.push({ path: p.key, expected: p.value })
          }
          checks = chk
          i = ni
          continue
        }
        "set" => {
          match line.value {
            Some(inline) => {
              // Inline form: `set: token = data.token`
              match split_assignment(inline) {
                Some((name, path)) => sets.push({ name, path })
                None =>
                  return (
                    Err(
                      "line \{line.line_no}: set expects \"name = json.path\", got \"\{inline}\"",
                    ),
                    i + 1,
                  )
              }
              i = i + 1
            }
            None => {
              // Block form:
              //   set:
              //     token: data.token
              let (pairs, ni) = parse_pairs(lines, i + 1, line.indent)
              if pairs.length() == 0 {
                return (Err("line \{line.line_no}: set block is empty"), i + 1)
              }
              for p in pairs {
                if p.value.length() == 0 {
                  return (
                    Err(
                      "line \{line.line_no}: set \"\{p.key}\" needs a json path",
                    ),
                    ni,
                  )
                }
                sets.push({ name: p.key, path: p.value })
              }
              i = ni
            }
          }
          continue
        }
        _ => {
          return (
            Err("line \{line.line_no}: unknown expect field \"\{line.key}\""),
            i + 1,
          )
        }
      }
      i = i + 1
    } else {
      i = i + 1
    }
  }
  return (Ok({ status, checks, sets }), i)
}

/// Split an inline `name = json.path` assignment on the first `=`, trimming
/// both sides. Returns `None` when either side is empty.
fn split_assignment(s : String) -> Option[(String, String)] {
  match s.split_once("=") {
    Some((name, path)) => {
      let n = name.trim().to_owned()
      let p = path.trim().to_owned()
      if n.length() == 0 || p.length() == 0 {
        return None
      }
      return Some((n, p))
    }
    None => None
  }
}

/// Collect a list of `key: value` pairs that are direct children of the line
/// at `sub_parent_indent` (the block header line's own indentation).
fn parse_pairs(
  lines : Array[LexedLine],
  start : Int,
  sub_parent_indent : Int
) -> (Array[Pair], Int) {
  let out : Array[Pair] = []
  let item_indent = child_indent_of(lines, start, sub_parent_indent)
  let mut i = start
  while i < lines.length() {
    let line = lines[i]
    if line.indent <= sub_parent_indent {
      break
    }
    if line.indent == item_indent {
      match line.value {
        Some(v) => {
          out.push({ key: line.key, value: v })
          i = i + 1
        }
        None => {
          out.push({ key: line.key, value: "" })
          i = i + 1
        }
      }
    } else {
      i = i + 1
    }
  }
  return (out, i)
}

/// Parse a decimal integer, returning `None` on non-numeric input.
fn parse_int(s : String) -> Option[Int] {
  let n = s.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  let mut sign = 1
  if s.at(i).to_int() == 0x2d {
    sign = -1
    i = i + 1
  }
  let mut acc = 0
  let mut any = false
  while i < n {
    let b = s.at(i).to_int()
    if b >= 0x30 && b <= 0x39 {
      acc = acc * 10 + (b - 0x30)
      any = true
    } else {
      return None
    }
    i = i + 1
  }
  if !any {
    return None
  }
  return Some(sign * acc)
}