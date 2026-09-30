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

///|
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
        "line \{line.line_no}: unexpected top-level key \"\{line.key}\"",
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
    cases.push(
      match case_result {
        Ok(c) => c
        Err(msg) => return Err(msg)
      },
    )
    i = next
  }
  if cases.length() == 0 {
    return Err("no test case defined")
  }
  return Ok({ cases, })
}

///|
/// Indentation of a block's direct children: the indentation of the first line
/// deeper than `parent_indent`, scanning from `start`.
///
/// Returns `-1` when the block has no body. Deriving the child indentation from
/// the source instead of assuming a fixed step keeps the parser independent of
/// whether the author indents with two, four or more spaces.
fn child_indent_of(
  lines : Array[LexedLine],
  start : Int,
  parent_indent : Int,
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

///|
/// Parse the request + expect blocks belonging to one case.
fn parse_case(
  names : String,
  lines : Array[LexedLine],
  start : Int,
  parent_indent : Int,
) -> (Result[Case, String], Int) {
  let mut request : Request? = None
  let mut expect : Expect? = None
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
        return (
          Err("line \{line.line_no}: unknown case key \"\{line.key}\""),
          i + 1,
        )
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
  return (Ok({ name: names, request: req, expect: exp, }), i)
}

///|
/// Parse a `request:` block. `parent_indent` is the indentation of the
/// `request:` line itself; its children live one level deeper.
fn parse_request(
  lines : Array[LexedLine],
  start : Int,
  parent_indent : Int,
) -> (Result[Request, String], Int) {
  let mut http_method = "GET"
  let mut url : String? = None
  let mut body : String? = None
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
        "url" =>
          url = match line.value {
            Some(v) => Some(v)
            None =>
              return (Err("line \{line.line_no}: url requires a value"), i)
          }
        "body" => body = line.value
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
        _ =>
          return (
            Err("line \{line.line_no}: unknown request field \"\{line.key}\""),
            i + 1,
          )
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
  return (Ok({ http_method, url: u, headers, query, body, }), i)
}

///|
/// Parse an `expect:` block.
///
/// Every expectation family may appear in any order and any number of times:
///
/// ```text
/// expect:
///   status: 200            # exact response code
///   json:                  # scalar equality at a dotted path
///     code: 0
///   type:                  # JSON type of a field
///     code: Int
///   length:                # exact element count of a JSON array
///     data.items: 3
///   contains: "ok"         # raw body must contain this text
///   contains_ci: "OK"      # ... ignoring ASCII case
///   duration_ms < 500      # request budget, in milliseconds
///   schema:                # structure the whole body must have
///     id: int!
///     profile: object
///       email: string!
///   set: token = data.token
/// ```
fn parse_expect(
  lines : Array[LexedLine],
  start : Int,
  parent_indent : Int,
) -> (Result[Expect, String], Int) {
  let mut status : Int? = None
  let mut checks : Array[JsonCheck] = []
  let contains : Array[ContainsCheck] = []
  let lengths : Array[LengthCheck] = []
  let types : Array[TypeCheck] = []
  let mut duration : DurationCheck? = None
  let mut schema : Array[SchemaField] = []
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
            None =>
              return (Err("line \{line.line_no}: invalid status \"\{v}\""), i)
          }
        }
        "json" => {
          let (pairs, ni) = parse_pairs(lines, i + 1, line.indent)
          let chk : Array[JsonCheck] = []
          for p in pairs {
            chk.push({ path: p.key, expected: p.value, })
          }
          checks = chk
          i = ni
          continue
        }
        "contains" =>
          match line.value {
            Some(text) => contains.push({ needle: text, ignore_case: false, })
            None =>
              return (
                Err(
                  "line \{line.line_no}: contains requires the text to look for",
                ),
                i + 1,
              )
          }
        "contains_ci" =>
          match line.value {
            Some(text) => contains.push({ needle: text, ignore_case: true, })
            None =>
              return (
                Err(
                  "line \{line.line_no}: contains_ci requires the text to look for",
                ),
                i + 1,
              )
          }
        "length" => {
          let (result, ni) = parse_length_entries(lines, i, line.indent)
          match result {
            Ok(entries) =>
              for entry in entries {
                lengths.push(entry)
              }
            Err(msg) => return (Err(msg), ni)
          }
          i = ni
          continue
        }
        "type" => {
          let (result, ni) = parse_type_entries(lines, i, line.indent)
          match result {
            Ok(entries) =>
              for entry in entries {
                types.push(entry)
              }
            Err(msg) => return (Err(msg), ni)
          }
          i = ni
          continue
        }
        "duration_ms" => {
          let raw = match line.value {
            Some(text) => text
            None =>
              return (
                Err(
                  "line \{line.line_no}: duration_ms needs a budget, e.g. \"duration_ms < 500\"",
                ),
                i + 1,
              )
          }
          let (op, limit) = match split_comparison_value(raw) {
            Some(parts) => parts
            None =>
              return (
                Err(
                  "line \{line.line_no}: invalid duration comparison \"\{raw}\"",
                ),
                i + 1,
              )
          }
          if limit < 0 {
            return (
              Err("line \{line.line_no}: duration budget must not be negative"),
              i + 1,
            )
          }
          duration = Some({ op, limit_ms: limit, })
        }
        "schema" => {
          match line.value {
            Some(_) =>
              return (
                Err(
                  "line \{line.line_no}: schema takes a block, e.g. \"schema:\" followed by \"id: int!\"",
                ),
                i + 1,
              )
            None => ()
          }
          let (result, ni) = parse_schema_fields(lines, i + 1, line.indent)
          match result {
            Ok(fields) => {
              if fields.length() == 0 {
                return (
                  Err("line \{line.line_no}: schema block is empty"),
                  i + 1,
                )
              }
              schema = fields
            }
            Err(msg) => return (Err(msg), ni)
          }
          i = ni
          continue
        }
        "set" => {
          match line.value {
            Some(inline) => {
              // Inline form: `set: token = data.token`
              match split_assignment(inline) {
                Some((name, path)) => sets.push({ name, path, })
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
                sets.push({ name: p.key, path: p.value, })
              }
              i = ni
            }
          }
          continue
        }
        _ =>
          return (
            Err("line \{line.line_no}: unknown expect field \"\{line.key}\""),
            i + 1,
          )
      }
      i = i + 1
    } else {
      i = i + 1
    }
  }
  return (
    Ok({ status, checks, sets, contains, lengths, types, duration, schema, }),
    i,
  )
}

///|
/// Parse a `length:` entry.
///
/// Both spellings are accepted: an inline size for the body root
/// (`length: 3`) and a block of path/size pairs (`length:` followed by
/// `data.items: 3`). Returns the entries together with the index of the first
/// line that does not belong to this entry.
fn parse_length_entries(
  lines : Array[LexedLine],
  index : Int,
  indent : Int,
) -> (Result[Array[LengthCheck], String], Int) {
  let line = lines[index]
  let out : Array[LengthCheck] = []
  match line.value {
    Some(text) => {
      let size = match parse_size(text) {
        Some(n) => n
        None =>
          return (
            Err("line \{line.line_no}: invalid length \"\{text}\""),
            index + 1,
          )
      }
      out.push({ path: "", size, })
      return (Ok(out), index + 1)
    }
    None => {
      let (pairs, ni) = parse_pairs(lines, index + 1, indent)
      if pairs.length() == 0 {
        return (Err("line \{line.line_no}: length block is empty"), index + 1)
      }
      for pair in pairs {
        let size = match parse_size(pair.value) {
          Some(n) => n
          None =>
            return (
              Err(
                "line \{line.line_no}: length of \"\{pair.key}\" must be a non-negative integer, got \"\{pair.value}\"",
              ),
              ni,
            )
        }
        out.push({ path: pair.key, size, })
      }
      return (Ok(out), ni)
    }
  }
}

///|
/// Parse a `type:` entry, in either the inline form (`type: object`) or the
/// block form (`type:` followed by `code: Int`).
fn parse_type_entries(
  lines : Array[LexedLine],
  index : Int,
  indent : Int,
) -> (Result[Array[TypeCheck], String], Int) {
  let line = lines[index]
  let out : Array[TypeCheck] = []
  match line.value {
    Some(text) => {
      let expected = match json_type_of(text) {
        Some(t) => t
        None =>
          return (
            Err(
              "line \{line.line_no}: unknown json type \"\{text}\", expected one of string, int, number, bool, null, object, array",
            ),
            index + 1,
          )
      }
      out.push({ path: "", expected, })
      return (Ok(out), index + 1)
    }
    None => {
      let (pairs, ni) = parse_pairs(lines, index + 1, indent)
      if pairs.length() == 0 {
        return (Err("line \{line.line_no}: type block is empty"), index + 1)
      }
      for pair in pairs {
        let expected = match json_type_of(pair.value) {
          Some(t) => t
          None =>
            return (
              Err(
                "line \{line.line_no}: unknown json type \"\{pair.value}\" for \"\{pair.key}\"",
              ),
              ni,
            )
        }
        out.push({ path: pair.key, expected, })
      }
      return (Ok(out), ni)
    }
  }
}

///|
/// Parse a `schema:` block into the flat field list of one object level.
///
/// A field is `<name>: <type>` with an optional trailing `!` marking it as
/// required. When the type is `object`, the lines indented under it are parsed
/// recursively as that object's own fields, which is what makes nested
/// structures expressible without any bracket syntax.
fn parse_schema_fields(
  lines : Array[LexedLine],
  start : Int,
  parent_indent : Int,
) -> (Result[Array[SchemaField], String], Int) {
  let out : Array[SchemaField] = []
  let field_indent = child_indent_of(lines, start, parent_indent)
  let mut i = start
  while i < lines.length() {
    let line = lines[i]
    if line.indent <= parent_indent {
      break
    }
    if line.indent == field_indent {
      let raw = match line.value {
        Some(text) => text
        None =>
          return (
            Err(
              "line \{line.line_no}: schema field \"\{line.key}\" needs a type, e.g. \"\{line.key}: string\"",
            ),
            i + 1,
          )
      }
      let (type_text, required) = strip_required(raw)
      let field_type = match json_type_of(type_text) {
        Some(t) => t
        None =>
          return (
            Err(
              "line \{line.line_no}: unknown schema type \"\{type_text}\" for \"\{line.key}\"",
            ),
            i + 1,
          )
      }
      let (nested, ni) = parse_schema_fields(lines, i + 1, line.indent)
      let children = match nested {
        Ok(v) => v
        Err(msg) => return (Err(msg), i)
      }
      if children.length() > 0 && field_type != TypeObject {
        return (
          Err(
            "line \{line.line_no}: only an \"object\" field may declare nested fields",
          ),
          i + 1,
        )
      }
      out.push({ name: line.key, required, field_type, children, })
      i = ni
      continue
    } else {
      i = i + 1
    }
  }
  return (Ok(out), i)
}

///|
/// Split the trailing `!` that marks a schema field as required off its type
/// name, e.g. `int!` into `("int", true)`.
fn strip_required(raw : String) -> (String, Bool) {
  let text = trim(raw)
  if text.has_suffix("!") {
    let head = text
      .view(start_offset=0, end_offset=text.length() - 1)
      .to_owned()
    return (trim(head), true)
  }
  return (text, false)
}

///|
/// Parse a non-negative integer, used by the `length:` expectation.
fn parse_size(text : String) -> Int? {
  match parse_int(trim(text)) {
    Some(n) => if n < 0 { None } else { Some(n) }
    None => None
  }
}

///|
/// Map a type name written in a `.probe` file onto the JSON type it denotes.
///
/// Matching ignores ASCII case and accepts the usual aliases, so `bool`,
/// `Bool` and `boolean` all mean the same thing. Returns `None` for a name that
/// denotes nothing, which is what makes a typo in a `type:` or `schema:` block
/// a parse error rather than a silently ignored expectation.
pub fn json_type_of(text : String) -> JsonType? {
  let name = trim(text)
  if name_matches(name, "string") || name_matches(name, "str") {
    return Some(JsonType::TypeString)
  }
  if name_matches(name, "int") || name_matches(name, "integer") {
    return Some(JsonType::TypeInt)
  }
  if name_matches(name, "number") ||
    name_matches(name, "float") ||
    name_matches(name, "double") {
    return Some(JsonType::TypeNumber)
  }
  if name_matches(name, "bool") || name_matches(name, "boolean") {
    return Some(JsonType::TypeBool)
  }
  if name_matches(name, "null") {
    return Some(JsonType::TypeNull)
  }
  if name_matches(name, "object") || name_matches(name, "map") {
    return Some(JsonType::TypeObject)
  }
  if name_matches(name, "array") || name_matches(name, "list") {
    return Some(JsonType::TypeArray)
  }
  return None
}

///|
/// Whether two short names are equal when ASCII case is folded.
fn name_matches(text : String, candidate : String) -> Bool {
  if text.length() != candidate.length() {
    return false
  }
  let mut i = 0
  while i < text.length() {
    if fold_ascii(text.at(i).to_int()) != fold_ascii(candidate.at(i).to_int()) {
      return false
    }
    i = i + 1
  }
  return true
}

///|
/// Fold one ASCII letter to lower case, leaving every other code point alone.
fn fold_ascii(code : Int) -> Int {
  if code >= 0x41 && code <= 0x5a {
    return code + 0x20
  }
  return code
}

///|
/// Split the value of a `duration_ms` assertion, e.g. `< 500`, into its
/// operator and its bound in milliseconds.
fn split_comparison_value(text : String) -> (String, Int)? {
  let value = trim(text)
  let operators : Array[String] = ["<=", ">=", "==", "!=", "<", ">"]
  for op in operators {
    if value.has_prefix(op) {
      let rest = trim(value.view(start_offset=op.length()).to_owned())
      match parse_int(rest) {
        Some(limit) => return Some((op, limit))
        None => return None
      }
    }
  }
  return None
}

///|
/// Split an inline `name = json.path` assignment on the first `=`, trimming
/// both sides. Returns `None` when either side is empty.
fn split_assignment(s : String) -> (String, String)? {
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

///|
/// Collect a list of `key: value` pairs that are direct children of the line
/// at `sub_parent_indent` (the block header line's own indentation).
fn parse_pairs(
  lines : Array[LexedLine],
  start : Int,
  sub_parent_indent : Int,
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
          out.push({ key: line.key, value: v, })
          i = i + 1
        }
        None => {
          out.push({ key: line.key, value: "", })
          i = i + 1
        }
      }
    } else {
      i = i + 1
    }
  }
  return (out, i)
}

///|
/// Parse a decimal integer, returning `None` on non-numeric input.
fn parse_int(s : String) -> Int? {
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
