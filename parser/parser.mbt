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
///
/// Three preamble blocks may open the file, before the first `name:` line:
/// `config:`, which holds the suite-wide defaults the runner merges into every
/// case, and `before_each: ` / `after_each:`, which hold the steps the runner
/// performs around every case of the file.
pub fn parse(src : String) -> Result[Suite, String] {
  let lines = match lex(src) {
    Ok(v) => v
    Err(msg) => return Err(msg)
  }
  if lines.length() == 0 {
    return Err("empty suite: no test case found")
  }
  let cases : Array[Case] = []
  let mut config : Config? = None
  let mut before_hooks : Array[Case]? = None
  let mut after_hooks : Array[Case]? = None
  let mut i = 0
  while i < lines.length() {
    let line = lines[i]
    if line.indent != 0 {
      return Err("line \{line.line_no}: unexpected indentation at top level")
    }
    if line.key == "config" {
      // The config block is a preamble: it may open the file, and only once. A
      // second one could not mean anything, since the first has already been
      // parsed and the cases after it were read against those defaults.
      match config {
        Some(_) => return Err("line \{line.line_no}: duplicate config block")
        None => ()
      }
      let (parsed, next) = parse_config(lines, i + 1, line.indent, line.line_no)
      config = match parsed {
        Ok(c) => Some(c)
        Err(msg) => return Err(msg)
      }
      i = next
      continue
    }
    if line.key == "before_each" || line.key == "after_each" {
      // Hooks are preamble too, and for the same reason: a hook declared after
      // the first case would leave that case unhooked, which reads as a bug in
      // the file rather than as an intention.
      if cases.length() > 0 {
        return Err(
          "line \{line.line_no}: the \{line.key} block must appear before the first case",
        )
      }
      let existing = if line.key == "before_each" {
        before_hooks
      } else {
        after_hooks
      }
      match existing {
        Some(_) =>
          return Err("line \{line.line_no}: duplicate \{line.key} block")
        None => ()
      }
      let (parsed, next) = parse_hook_cases(
        lines,
        i + 1,
        line.indent,
        line.key,
        line.line_no,
      )
      let steps = match parsed {
        Ok(v) => v
        Err(msg) => return Err(msg)
      }
      if line.key == "before_each" {
        before_hooks = Some(steps)
      } else {
        after_hooks = Some(steps)
      }
      i = next
      continue
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
    let (case_result, next) = parse_case(name, lines, i, 0, true)
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
  let resolved = match config {
    Some(c) => c
    None => default_config()
  }
  return Ok({
    config: resolved,
    cases,
    before_each: before_hooks.unwrap_or([]),
    after_each: after_hooks.unwrap_or([]),
  })
}

///|
/// Parse a `before_each:` / `after_each:` block, whose direct children are
/// complete cases — one `name:` per step:
///
/// ```text
/// before_each:
///   name: "sign in"                # --- one step, a full case ---
///   request:
///     method: POST
///     url: "/login"
///   expect:
///     status: 200
///     set: token = data.access_token
/// ```
///
/// Reusing the case grammar gives a hook everything a case has: it may send a
/// body, assert on the reply, and bind variables with `set:`, which is what
/// makes a login step usable by the cases that follow it.
///
/// `block_line` is the line number of the `before_each:` line itself, so the
/// "empty block" message can point at it.
fn parse_hook_cases(
  lines : Array[LexedLine],
  start : Int,
  parent_indent : Int,
  block : String,
  block_line : Int,
) -> (Result[Array[Case], String], Int) {
  if start >= lines.length() || lines[start].indent <= parent_indent {
    return (
      Err(
        "line \{block_line}: the \{block} block is empty, e.g. \"\{block}:\" followed by a \"name:\" step",
      ),
      start,
    )
  }
  let steps : Array[Case] = []
  let step_indent = lines[start].indent
  let mut i = start
  while i < lines.length() && lines[i].indent == step_indent {
    let line = lines[i]
    if line.key != "name" {
      return (
        Err(
          "line \{line.line_no}: a \{block} step must start with \"name:\", got \"\{line.key}:\"",
        ),
        i + 1,
      )
    }
    let name = line.value.unwrap_or("")
    if name.length() == 0 {
      return (
        Err("line \{line.line_no}: \{block} step name must not be empty"),
        i + 1,
      )
    }
    // A step is a case, so it is read with the same routine — but hooks the step
    // itself declared would never run, so those are rejected there instead.
    let (parsed, next) = parse_case(name, lines, i + 1, step_indent, false)
    match parsed {
      Ok(step) => steps.push(step)
      Err(msg) => return (Err(msg), next)
    }
    i = next
  }
  return (Ok(steps), i)
}

///|
/// The largest retry budget a `.probe` file may declare.
///
/// A request is retried immediately rather than after a delay, so an absurd
/// budget would not fail — it would hang the run. The cap keeps a typo such as
/// `retry: 100000` from turning a build job into a timeout.
const MAX_RETRY_COUNT : Int = 10

///|
/// Parse a `retry:` field, shared by the config block and a request block so
/// that both accept exactly the same values and report the same errors.
fn parse_retry_count(line : LexedLine) -> Result[Int, String] {
  let value = match line.value {
    Some(v) => v
    None =>
      return Err(
        "line \{line.line_no}: retry requires a value, i.e. how many extra attempts are allowed",
      )
  }
  match parse_int(value) {
    Some(n) =>
      if n < 0 {
        return Err("line \{line.line_no}: retry must not be negative")
      } else if n > MAX_RETRY_COUNT {
        return Err(
          "line \{line.line_no}: retry must not exceed \{MAX_RETRY_COUNT}",
        )
      } else {
        return Ok(n)
      }
    None =>
      return Err(
        "line \{line.line_no}: invalid retry \"\{value}\", expected a number of extra attempts",
      )
  }
}

///|
/// Parse a `config:` block, the suite-wide preamble of a `.probe` file:
///
/// ```text
/// config:
///   base_url: "https://api.example.com"   # relative urls resolve against it
///   global_timeout: 8000                  # per-request timeout, in ms
///   global_headers:                       # sent with every case
///     Authorization: "Bearer ${API_TOKEN}"
///     Accept: "application/json"
/// ```
///
/// `base_url` and `global_timeout` are single values; `global_headers` is a
/// block of `name: value` pairs, exactly like a request's `headers:` block.
fn parse_config(
  lines : Array[LexedLine],
  start : Int,
  parent_indent : Int,
  line_no : Int,
) -> (Result[Config, String], Int) {
  let mut base_url : String? = None
  let mut timeout_ms : Int? = None
  let mut retry_count : Int? = None
  let mut headers : Array[Pair] = []
  let field_indent = child_indent_of(lines, start, parent_indent)
  if field_indent < 0 {
    return (
      Err(
        "line \{line_no}: config block is empty, e.g. \"config:\" followed by \"base_url: ...\"",
      ),
      start,
    )
  }
  let mut i = start
  while i < lines.length() {
    let line = lines[i]
    if line.indent <= parent_indent {
      break
    }
    if line.indent != field_indent {
      return (
        Err("line \{line.line_no}: unexpected nesting inside the config block"),
        i + 1,
      )
    }
    match line.key {
      "base_url" => {
        let value = match line.value {
          Some(v) => v
          None =>
            return (
              Err("line \{line.line_no}: base_url requires a value"),
              i + 1,
            )
        }
        if !is_absolute_url(value) {
          return (
            Err(
              "line \{line.line_no}: base_url must be an absolute http(s) url, got \"\{value}\"",
            ),
            i + 1,
          )
        }
        base_url = Some(value)
      }
      "global_timeout" => {
        let value = match line.value {
          Some(v) => v
          None =>
            return (
              Err("line \{line.line_no}: global_timeout requires a value"),
              i + 1,
            )
        }
        timeout_ms = match parse_int(value) {
          Some(n) =>
            if n < 0 {
              return (
                Err("line \{line.line_no}: global_timeout must not be negative"),
                i + 1,
              )
            } else {
              Some(n)
            }
          None =>
            return (
              Err(
                "line \{line.line_no}: invalid global_timeout \"\{value}\", expected milliseconds",
              ),
              i + 1,
            )
        }
      }
      "retry" =>
        retry_count = match parse_retry_count(line) {
          Ok(n) => Some(n)
          Err(msg) => return (Err(msg), i + 1)
        }
      "global_headers" => {
        let (pairs, ni) = parse_pairs(lines, i + 1, line.indent)
        headers = pairs
        i = ni
        continue
      }
      _ =>
        return (
          Err("line \{line.line_no}: unknown config key \"\{line.key}\""),
          i + 1,
        )
    }
    i = i + 1
  }
  return (
    Ok({
      base_url,
      global_headers: headers,
      global_timeout_ms: timeout_ms,
      retry_count,
    }),
    i,
  )
}

///|
/// Whether `text` starts with `prefix`, ignoring ASCII case.
///
/// A `base_url` may be written with any casing of the scheme (`HTTP://`,
/// `https://`), and the same helper serves the `header`/`cookie` prefixes of a
/// `set:` path, so the comparison is folded rather than exact.
fn starts_with_ignore_case(text : String, prefix : String) -> Bool {
  if text.length() < prefix.length() {
    return false
  }
  let mut i = 0
  while i < prefix.length() {
    if fold_ascii(text.at(i).to_int()) != fold_ascii(prefix.at(i).to_int()) {
      return false
    }
    i = i + 1
  }
  return true
}

///|
/// Whether two strings are equal when ASCII case is folded on both sides.
fn equals_ignore_case(left : String, right : String) -> Bool {
  return left.length() == right.length() && starts_with_ignore_case(left, right)
}

///|
/// Whether `text` is an absolute HTTP(S) URL, which is what a `base_url` has to
/// be: a relative one could not be resolved against anything.
fn is_absolute_url(text : String) -> Bool {
  return starts_with_ignore_case(text, "http://") ||
    starts_with_ignore_case(text, "https://")
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
///
/// `allow_hooks` is false while a `before_each:` / `after_each:` block is being
/// read: a step there is a case like any other, except that the runner would
/// never reach hooks the step declared of its own, so accepting them would mean
/// silently doing nothing.
fn parse_case(
  names : String,
  lines : Array[LexedLine],
  start : Int,
  parent_indent : Int,
  allow_hooks : Bool,
) -> (Result[Case, String], Int) {
  let mut request : Request? = None
  let mut expect : Expect? = None
  let mut before_hooks : Array[Case]? = None
  let mut after_hooks : Array[Case]? = None
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
      } else if line.key == "config" ||
        line.key == "before_each" ||
        line.key == "after_each" {
        if !allow_hooks {
          return (
            Err(
              "line \{line.line_no}: a hook step cannot declare its own \"\{line.key}:\" block",
            ),
            i + 1,
          )
        }
        if line.key == "config" {
          // Reached only when a `config:` block follows a case: the preamble slot
          // is the top of the file, and it has already gone by.
          return (
            Err(
              "line \{line.line_no}: the config block must appear before the first case",
            ),
            i + 1,
          )
        }
        let existing = if line.key == "before_each" {
          before_hooks
        } else {
          after_hooks
        }
        match existing {
          Some(_) =>
            return (
              Err("line \{line.line_no}: duplicate \{line.key} block"),
              i + 1,
            )
          None => ()
        }
        let (h, ni) = parse_hook_cases(
          lines,
          i + 1,
          line.indent,
          line.key,
          line.line_no,
        )
        let steps = match h {
          Ok(v) => v
          Err(msg) => return (Err(msg), ni)
        }
        if line.key == "before_each" {
          before_hooks = Some(steps)
        } else {
          after_hooks = Some(steps)
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
  return (
    Ok({
      name: names,
      request: req,
      expect: exp,
      before_each: before_hooks.unwrap_or([]),
      after_each: after_hooks.unwrap_or([]),
    }),
    i,
  )
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
  let mut timeout_ms : Int? = None
  let mut retry_count : Int? = None
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
        "timeout" => {
          let value = match line.value {
            Some(v) => v
            None =>
              return (
                Err(
                  "line \{line.line_no}: timeout requires a value in milliseconds",
                ),
                i + 1,
              )
          }
          timeout_ms = match parse_int(value) {
            Some(n) =>
              if n < 0 {
                return (
                  Err("line \{line.line_no}: timeout must not be negative"),
                  i + 1,
                )
              } else {
                Some(n)
              }
            None =>
              return (
                Err(
                  "line \{line.line_no}: invalid timeout \"\{value}\", expected milliseconds",
                ),
                i + 1,
              )
          }
        }
        "retry" =>
          retry_count = match parse_retry_count(line) {
            Ok(n) => Some(n)
            Err(msg) => return (Err(msg), i + 1)
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
  return (
    Ok({ http_method, url: u, headers, query, body, timeout_ms, retry_count, }),
    i,
  )
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
                Some((name, path)) =>
                  match parse_set_target(name, path) {
                    Ok(spec) => sets.push(spec)
                    Err(msg) =>
                      return (Err("line \{line.line_no}: \{msg}"), i + 1)
                  }
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
                      "line \{line.line_no}: set \"\{p.key}\" needs a source, e.g. \"data.token\"",
                    ),
                    ni,
                  )
                }
                match parse_set_target(p.key, p.value) {
                  Ok(spec) => sets.push(spec)
                  Err(msg) => return (Err("line \{line.line_no}: \{msg}"), ni)
                }
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
/// Build the extraction a `set:` directive declares from its variable name and
/// its source text.
///
/// The source carries the origin as a prefix, so all three places a value can
/// come from are written the same way:
///
/// ```text
/// set: token  = data.access_token    # response body, dotted json path
/// set: trace  = body.data.trace_id   # ... spelled out explicitly
/// set: sid    = header.X-Session-Id  # response header, matched by name
/// set: csrf   = cookie.csrf_token    # cookie the server set
/// ```
///
/// A source without a known prefix is a body path, which keeps the original
/// `set: token = data.token` spelling working unchanged.
fn parse_set_target(name : String, target : String) -> Result[SetSpec, String] {
  if name.length() == 0 {
    return Err("set needs a variable name")
  }
  let (head, rest) = match target.split_once(".") {
    Some((head, rest)) => (head.to_owned(), rest.to_owned())
    None => (target, "")
  }
  let source = if equals_ignore_case(head, "header") ||
    equals_ignore_case(head, "headers") {
    FromHeader
  } else if equals_ignore_case(head, "cookie") ||
    equals_ignore_case(head, "cookies") {
    FromCookie
  } else if equals_ignore_case(head, "body") || equals_ignore_case(head, "json") {
    FromBody
  } else {
    // No recognised prefix: the whole source is a body path.
    return Ok({ name, source: FromBody, path: target, })
  }
  let path = trim(rest)
  if path.length() == 0 {
    return Err(
      "set \"\{name}\": \"\{head}.\" needs a name after the dot, e.g. \"\{head}.X-Token\"",
    )
  }
  return Ok({ name, source, path, })
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
