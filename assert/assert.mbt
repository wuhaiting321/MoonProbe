/// MoonProbe - assert
///
/// The assertion engine compares a response against the `expect:` block of a
/// parsed `.probe` case.
///
/// A check reports a failure as text instead of raising, so that one mismatching
/// field never hides the others: `check_expect` runs the whole block and hands
/// back every message it collected.
///
/// Seven families of check are supported, each one independently:
///
///   - `status:`      the HTTP status code
///   - `json:`        scalar equality at a dotted path
///   - `type:`        the JSON type a field must hold
///   - `length:`      the exact element count of a JSON array
///   - `contains:`    a substring of the raw body, case-sensitive or folded
///   - `duration_ms`  a budget on how long the request itself took
///   - `schema:`      the structure of the whole body

// ---------------------------------------------------------------------------
// Response decoding
// ---------------------------------------------------------------------------

///|
/// Decode a response body, turning a decoder failure into a readable message.
///
/// A body that is not valid JSON is reported but never aborts the run: the
/// caller decides whether that is a failure (as for `json:` and `schema:`) or
/// simply irrelevant (as for `contains:` and `duration_ms`).
fn decode_body(body : String) -> Result[Json, String] {
  let json = @json.parse(body) catch {
    err => return Err("response body is not valid json (\{err})")
  }
  return Ok(json)
}

///|
/// Compare the response status against the expected one.
pub fn check_status(expected : Int, actual : Int) -> Result[Unit, String] {
  if expected == actual {
    return Ok(())
  }
  return Err("status: expected \{expected}, got \{actual}")
}

///|
/// Render a JSON value as the text an expectation is written as.
///
/// Only scalars have such a form — an expectation is always a plain string in
/// the `.probe` source — so objects and arrays cannot be compared.
fn json_text(json : Json) -> String? {
  match json {
    Null => Some("null")
    True => Some("true")
    False => Some("false")
    String(s) => Some(s)
    Number(n, repr~) =>
      match repr {
        Some(text) => Some(text)
        None => Some(n.to_string())
      }
    Array(_) => None
    Object(_) => None
  }
}

///|
/// Walk a dotted path such as `data.count` through the JSON objects of a
/// response body.
///
/// Returns `None` as soon as a segment is absent or the value reached on the
/// way is not an object. The empty path addresses the body root itself, which
/// is how a `length:` or `type:` assertion talks about the whole body.
fn lookup_path(json : Json, path : String) -> Json? {
  if path.length() == 0 {
    return Some(json)
  }
  let mut current = json
  for segment in path.split(".") {
    let next = match current {
      Object(fields) => fields.get(segment.to_owned())
      _ => None
    }
    match next {
      Some(value) => current = value
      None => return None
    }
  }
  return Some(current)
}

///|
/// Read the scalar value addressed by a dotted path such as `data.count` from an
/// already decoded body, rendered as text.
fn read_path_in(json : Json, path : String) -> Result[String, String] {
  let value = match lookup_path(json, path) {
    Some(v) => v
    None => return Err("path \"\{path}\" not found in the response body")
  }
  match json_text(value) {
    Some(text) => Ok(text)
    None => Err("path \"\{path}\" is not a scalar value and cannot be compared")
  }
}

///|
/// Read the scalar value addressed by a dotted path such as `data.count` from a
/// JSON response body, rendered as text.
///
/// This is the read half of `check_json_path`, exposed so that the runner can
/// also use it to extract variables declared by a `set:` directive.
pub fn read_json_path(body : String, path : String) -> Result[String, String] {
  let json = match decode_body(body) {
    Ok(value) => value
    Err(msg) => return Err(msg)
  }
  return read_path_in(json, path)
}

///|
/// Compare one JSON field, addressed by a dotted path, against the text written
/// in the `.probe` expectation.
pub fn check_json_path(
  body : String,
  path : String,
  expected : String,
) -> Result[Unit, String] {
  let actual = match read_json_path(body, path) {
    Ok(text) => text
    Err(msg) => return Err("json: \{msg}")
  }
  if actual == expected {
    return Ok(())
  }
  return Err("json: \{path}: expected \"\{expected}\", got \"\{actual}\"")
}

// ---------------------------------------------------------------------------
// JSON types
// ---------------------------------------------------------------------------

///|
/// Whether a decoded number holds an integral value, that is, one with no
/// fractional part.
///
/// The decoder only hands back the source text of a number for the rare values
/// a `Double` cannot preserve exactly, so the common case must be decided on the
/// value itself: `3` and `-2` are integral, `1.5` is not. `NaN` and the
/// infinities are excluded explicitly because `trunc` would accept them.
fn is_integral(n : Double) -> Bool {
  if n.is_nan() || n.is_inf() {
    return false
  }
  return n == n.trunc()
}

///|
/// The name of the JSON type a decoded value actually holds.
fn type_name(json : Json) -> String {
  match json {
    Null => "Null"
    True => "Bool"
    False => "Bool"
    String(_) => "String"
    Number(n, ..) => if is_integral(n) { "Int" } else { "Number" }
    Array(_) => "Array"
    Object(_) => "Object"
  }
}

///|
/// Whether a decoded value satisfies an expected JSON type.
fn json_matches_type(json : Json, expected : @parser.JsonType) -> Bool {
  match expected {
    TypeString =>
      match json {
        String(_) => true
        _ => false
      }
    TypeInt =>
      match json {
        Number(n, ..) => is_integral(n)
        _ => false
      }
    TypeNumber =>
      match json {
        Number(_, ..) => true
        _ => false
      }
    TypeBool =>
      match json {
        True => true
        False => true
        _ => false
      }
    TypeNull =>
      match json {
        Null => true
        _ => false
      }
    TypeObject =>
      match json {
        Object(_) => true
        _ => false
      }
    TypeArray =>
      match json {
        Array(_) => true
        _ => false
      }
  }
}

///|
/// How an expectation addresses the value it talks about, for use in a failure
/// message: the body root has no path to name, so it is called `body`.
fn label_of(path : String) -> String {
  if path.length() == 0 {
    return "body"
  }
  return "\"" + path + "\""
}

// ---------------------------------------------------------------------------
// contains
// ---------------------------------------------------------------------------

///|
/// Fold one ASCII letter to lower case, leaving every other code point alone.
///
/// Only ASCII is folded on purpose: a full Unicode case mapping would need
/// tables that would dwarf the rest of this package, and API status text is
/// ASCII in practice.
fn fold_ascii(code : Int) -> Int {
  if code >= 0x41 && code <= 0x5a {
    return code + 0x20
  }
  return code
}

///|
/// Whether `haystack` contains `needle` when ASCII case is folded on both sides.
fn contains_ignoring_case(haystack : String, needle : String) -> Bool {
  let n = needle.length()
  if n == 0 {
    return true
  }
  let limit = haystack.length() - n
  let mut start = 0
  while start <= limit {
    let mut offset = 0
    let mut matched = true
    while offset < n {
      let left = fold_ascii(haystack.at(start + offset).to_int())
      let right = fold_ascii(needle.at(offset).to_int())
      if left != right {
        matched = false
        break
      }
      offset = offset + 1
    }
    if matched {
      return true
    }
    start = start + 1
  }
  return false
}

///|
/// Require the raw response body to contain a piece of text.
///
/// `ignore_case` folds ASCII case on both sides, which is what a `contains_ci:`
/// expectation asks for. An empty needle is trivially contained.
pub fn check_contains(
  body : String,
  needle : String,
  ignore_case : Bool,
) -> Result[Unit, String] {
  let found = if needle.length() == 0 {
    true
  } else if ignore_case {
    contains_ignoring_case(body, needle)
  } else {
    body.contains(needle)
  }
  if found {
    return Ok(())
  }
  let how = if ignore_case { " (ignoring case)" } else { "" }
  return Err("contains: body does not contain \"\{needle}\"\{how}")
}

// ---------------------------------------------------------------------------
// length
// ---------------------------------------------------------------------------

///|
/// Require the JSON array at `path` to hold exactly `expected` elements, on an
/// already decoded body.
fn length_in(
  json : Json,
  path : String,
  expected : Int,
) -> Result[Unit, String] {
  let value = match lookup_path(json, path) {
    Some(v) => v
    None =>
      return Err("length: \{label_of(path)} not found in the response body")
  }
  match value {
    Array(items) =>
      if items.length() == expected {
        Ok(())
      } else {
        Err(
          "length: \{label_of(path)}: expected \{expected} elements, got \{items.length()}",
        )
      }
    other =>
      Err(
        "length: \{label_of(path)}: expected an array, got \{type_name(other)}",
      )
  }
}

///|
/// Require the JSON array at `path` in the response body to hold exactly
/// `expected` elements.
///
/// An empty path addresses the body root, so `length: 3` checks that the whole
/// body is an array of three items.
pub fn check_length(
  body : String,
  path : String,
  expected : Int,
) -> Result[Unit, String] {
  let json = match decode_body(body) {
    Ok(value) => value
    Err(msg) => return Err("length: \{msg}")
  }
  return length_in(json, path, expected)
}

// ---------------------------------------------------------------------------
// type
// ---------------------------------------------------------------------------

///|
/// Require the field at `path` to hold a given JSON type, on an already decoded
/// body.
fn type_in(
  json : Json,
  path : String,
  expected : @parser.JsonType,
) -> Result[Unit, String] {
  let value = match lookup_path(json, path) {
    Some(v) => v
    None => return Err("type: \{label_of(path)} not found in the response body")
  }
  if json_matches_type(value, expected) {
    return Ok(())
  }
  return Err(
    "type: \{label_of(path)}: expected \{expected.label()}, got \{type_name(value)}",
  )
}

///|
/// Require the field at a dotted path in the response body to hold a given JSON
/// type.
///
/// This catches an API that silently changed the type of a field — a count that
/// started coming back as a string, or a flag that turned into `0`/`1`.
pub fn check_json_type(
  body : String,
  path : String,
  expected : @parser.JsonType,
) -> Result[Unit, String] {
  let json = match decode_body(body) {
    Ok(value) => value
    Err(msg) => return Err("type: \{msg}")
  }
  return type_in(json, path, expected)
}

// ---------------------------------------------------------------------------
// duration_ms
// ---------------------------------------------------------------------------

///|
/// Apply a comparison operator to a measured duration and its bound.
fn compare_int(op : String, actual : Int, limit : Int) -> Bool {
  match op {
    "<" => actual < limit
    "<=" => actual <= limit
    ">" => actual > limit
    ">=" => actual >= limit
    "==" => actual == limit
    "!=" => actual != limit
    _ => false
  }
}

///|
/// Require a request to have taken no longer than the `.probe` file allows.
///
/// The duration is measured by the runner around the transport call alone, so
/// the assertion is about the server, not about the time the assertions
/// themselves need.
pub fn check_duration(
  expected : @parser.DurationCheck,
  actual_ms : UInt64,
) -> Result[Unit, String] {
  let actual : Int = actual_ms.to_int()
  if compare_int(expected.op, actual, expected.limit_ms) {
    return Ok(())
  }
  return Err(
    "duration: expected \{expected.op} \{expected.limit_ms} ms, took \{actual} ms",
  )
}

// ---------------------------------------------------------------------------
// schema
// ---------------------------------------------------------------------------

///|
/// Validate the fields of one object level against a decoded value.
///
/// Every problem found is appended to `out` rather than returned, so a schema
/// with three missing fields reports all three.
fn validate_fields(
  parent : Json,
  prefix : String,
  fields : Array[@parser.SchemaField],
  out : Array[String],
) -> Unit {
  for field in fields {
    let path = if prefix.length() == 0 {
      field.name
    } else {
      prefix + "." + field.name
    }
    let found = match parent {
      Object(entries) => entries.get(field.name)
      _ => None
    }
    match found {
      None =>
        if field.required {
          out.push("schema: \"\{path}\" is required but missing")
        }
      Some(value) =>
        if !json_matches_type(value, field.field_type) {
          out.push(
            "schema: \"\{path}\": expected \{field.field_type.label()}, got \{type_name(value)}",
          )
        } else if field.children.length() > 0 {
          validate_fields(value, path, field.children, out)
        }
    }
  }
}

///|
/// Validate a decoded body against a parsed schema block.
///
/// An empty schema accepts any body: a case that declares no `schema:` block
/// must not be reported as a structural failure.
fn validate_schema(
  json : Json,
  fields : Array[@parser.SchemaField],
) -> Array[String] {
  let out : Array[String] = []
  if fields.length() == 0 {
    return out
  }
  match json {
    Object(_) => validate_fields(json, "", fields, out)
    other =>
      out.push("schema: body: expected an Object, got \{type_name(other)}")
  }
  return out
}

///|
/// Validate the response body against a parsed schema block, returning one
/// message per problem found.
///
/// A body that is not valid JSON is reported as a single failure instead of
/// raising, so that a schema assertion behaves like every other one. The empty
/// schema is answered before the body is even decoded, because a body that is
/// not JSON is not a problem when nothing was asked of it.
pub fn check_schema(
  body : String,
  fields : Array[@parser.SchemaField],
) -> Array[String] {
  let out : Array[String] = []
  if fields.length() == 0 {
    return out
  }
  let json = match decode_body(body) {
    Ok(value) => value
    Err(msg) => {
      out.push("schema: \{msg}")
      return out
    }
  }
  return validate_schema(json, fields)
}

// ---------------------------------------------------------------------------
// The whole block
// ---------------------------------------------------------------------------

///|
/// Run every expectation of an `expect:` block against a response.
///
/// `elapsed_ms` is how long the request itself took, as measured by the runner;
/// it is what a `duration_ms` expectation is compared against.
///
/// Returns the failure messages in declaration order; an empty array means the
/// case passed. The body is decoded at most once for the checks that need JSON,
/// and never for the ones that work on the raw text.
pub fn check_expect(
  expect : @parser.Expect,
  status : Int,
  body : String,
  elapsed_ms : UInt64,
) -> Array[String] {
  let failures : Array[String] = []
  match expect.status {
    Some(expected) =>
      match check_status(expected, status) {
        Err(msg) => failures.push(msg)
        Ok(_) => ()
      }
    None => ()
  }
  for check in expect.checks {
    match check_json_path(body, check.path, check.expected) {
      Err(msg) => failures.push(msg)
      Ok(_) => ()
    }
  }
  for check in expect.contains {
    match check_contains(body, check.needle, check.ignore_case) {
      Err(msg) => failures.push(msg)
      Ok(_) => ()
    }
  }
  match expect.duration {
    Some(budget) =>
      match check_duration(budget, elapsed_ms) {
        Err(msg) => failures.push(msg)
        Ok(_) => ()
      }
    None => ()
  }
  // The structural checks need the decoded body; decode it once and only when
  // at least one of them was declared.
  if expect.lengths.length() > 0 ||
    expect.types.length() > 0 ||
    expect.schema.length() > 0 {
    match decode_body(body) {
      Ok(json) => {
        for check in expect.lengths {
          match length_in(json, check.path, check.size) {
            Err(msg) => failures.push(msg)
            Ok(_) => ()
          }
        }
        for check in expect.types {
          match type_in(json, check.path, check.expected) {
            Err(msg) => failures.push(msg)
            Ok(_) => ()
          }
        }
        for msg in validate_schema(json, expect.schema) {
          failures.push(msg)
        }
      }
      Err(msg) => {
        for check in expect.lengths {
          failures.push("length: \{label_of(check.path)}: \{msg}")
        }
        for check in expect.types {
          failures.push("type: \{label_of(check.path)}: \{msg}")
        }
        if expect.schema.length() > 0 {
          failures.push("schema: \{msg}")
        }
      }
    }
  }
  return failures
}
