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
///
/// The comparison is type-aware rather than textual, which is what stops the
/// two classic false passes:
///
///   - the number `7` satisfying an expectation of the number `999` (numbers
///     are compared by value, never by widening them to a common string), and
///   - the string `"7"` satisfying an expectation of the number `7` (a quoted
///     expectation only ever matches a JSON string).
///
/// Numbers are classified by integrality, the same rule `type:` uses: an
/// integral value is an `Int`, anything with a fractional part is a `Number`.
/// An integer expectation therefore requires an integral value, and a float
/// expectation requires a non-integral one.
pub fn check_json_path_typed(
  body : String,
  path : String,
  expected : String,
  quoted : Bool,
) -> Result[Unit, String] {
  let json = match decode_body(body) {
    Ok(value) => value
    Err(msg) => return Err("json: \{msg}")
  }
  return check_json_value(json, path, expected, quoted)
}

///|
/// Compare one JSON field, treating the expectation as unquoted source text.
///
/// This is the entry point for callers that build an expectation in code; the
/// runner goes through `check_json_path_typed` so that `code: "7"` and
/// `code: 7` remain distinct.
pub fn check_json_path(
  body : String,
  path : String,
  expected : String,
) -> Result[Unit, String] {
  return check_json_path_typed(body, path, expected, false)
}

///|
/// The literal an expectation denotes once its type is known.
///
/// The distinction between these five cases is the whole point of the strict
/// mode: the text `7` is an `ExpectedInt` while the text `"7"` is an
/// `ExpectedString`, and no comparison may collapse the two.
priv enum ExpectedLiteral {
  ExpectedInt(String)
  ExpectedFloat(String)
  ExpectedString(String)
  ExpectedBool(Bool)
  ExpectedNull
}

///|
/// Whether `code` is an ASCII digit.
fn is_digit_code(code : Int) -> Bool {
  return code >= 0x30 && code <= 0x39
}

///|
/// Classify an expectation into the JSON type it denotes.
///
/// A quoted expectation is always a string, whatever its text looks like. An
/// unquoted one is a number, `true`, `false` or `null` when it is written as
/// one, and otherwise a plain string — so the long-standing `name: alice`
/// spelling keeps meaning the string `alice`.
fn classify_expected(text : String, quoted : Bool) -> ExpectedLiteral {
  if quoted {
    return ExpectedString(text)
  }
  if text == "true" {
    return ExpectedBool(true)
  }
  if text == "false" {
    return ExpectedBool(false)
  }
  if text == "null" {
    return ExpectedNull
  }
  match number_literal_kind(text) {
    Some(_) =>
      // A literal is an `Int` or a `Number` by the value it denotes, not by how
      // it is spelled: `7.0` and `1e3` are both integral values, so they are
      // typed exactly like `7` and `1000`. This keeps `json:` and `type:`
      // agreeing on the same rule — a number's type comes from its value.
      if number_is_integral(text) {
        ExpectedInt(text)
      } else {
        ExpectedFloat(text)
      }
    None => ExpectedString(text)
  }
}

///|
/// Whether a JSON number literal denotes an integral value.
///
/// The canonical form carries this directly: the exponent counts how many
/// digits sit to the right of the significant ones, so an exponent of zero or
/// more means no fractional part survives. `1000.0` canonicalises to `1e3` and
/// is integral; `1.5` canonicalises to `15e-1` and is not.
fn number_is_integral(text : String) -> Bool {
  let canonical = match canonical_number(text) {
    Some(value) => value
    None => return false
  }
  let n = canonical.length()
  let mut i = 0
  while i < n {
    if canonical.at(i).to_int() == 0x65 {
      return !(i + 1 < n && canonical.at(i + 1).to_int() == 0x2d)
    }
    i = i + 1
  }
  return true
}

///|
/// Classify a JSON number literal.
///
/// Returns `Some(true)` for a literal with a fractional or exponent part,
/// `Some(false)` for a plain integer, and `None` when the text is not a JSON
/// number at all. The grammar is the JSON one: an optional minus, at least one
/// integer digit, an optional fraction, and an optional exponent.
fn number_literal_kind(text : String) -> Bool? {
  let n = text.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  if text.at(0).to_int() == 0x2d {
    i = 1
  }
  let digits_start = i
  while i < n && is_digit_code(text.at(i).to_int()) {
    i = i + 1
  }
  if i == digits_start {
    return None
  }
  let mut is_float = false
  if i < n && text.at(i).to_int() == 0x2e {
    is_float = true
    i = i + 1
    let fraction_start = i
    while i < n && is_digit_code(text.at(i).to_int()) {
      i = i + 1
    }
    if i == fraction_start {
      return None
    }
  }
  if i < n && (text.at(i).to_int() == 0x65 || text.at(i).to_int() == 0x45) {
    is_float = true
    i = i + 1
    if i < n && (text.at(i).to_int() == 0x2b || text.at(i).to_int() == 0x2d) {
      i = i + 1
    }
    let exponent_start = i
    while i < n && is_digit_code(text.at(i).to_int()) {
      i = i + 1
    }
    if i == exponent_start {
      return None
    }
  }
  if i != n {
    return None
  }
  return Some(is_float)
}

///|
/// Reduce a JSON number literal to a canonical `significant-digits e exponent`
/// form, so that two literals compare equal when they denote the same value.
///
/// This is why `1e3`, `1000` and `1000.0` all agree while `999` and `7` do
/// not, and why the comparison never goes through `Double` — a 19-digit integer
/// keeps every digit instead of rounding to the nearest float.
fn canonical_number(text : String) -> String? {
  match number_literal_kind(text) {
    None => return None
    Some(_) => ()
  }
  let n = text.length()
  let mut i = 0
  let negative = text.at(0).to_int() == 0x2d
  if negative {
    i = 1
  }
  let digits = StringBuilder()
  while i < n && is_digit_code(text.at(i).to_int()) {
    digits.write_char(text.at(i).to_int().to_char().unwrap())
    i = i + 1
  }
  let mut fraction_len = 0
  if i < n && text.at(i).to_int() == 0x2e {
    i = i + 1
    while i < n && is_digit_code(text.at(i).to_int()) {
      digits.write_char(text.at(i).to_int().to_char().unwrap())
      fraction_len = fraction_len + 1
      i = i + 1
    }
  }
  let mut exponent = 0
  if i < n {
    // The grammar check above leaves only `e`/`E` at this position.
    i = i + 1
    let mut exponent_negative = false
    if i < n && (text.at(i).to_int() == 0x2b || text.at(i).to_int() == 0x2d) {
      exponent_negative = text.at(i).to_int() == 0x2d
      i = i + 1
    }
    let mut magnitude = 0
    while i < n && is_digit_code(text.at(i).to_int()) {
      magnitude = magnitude * 10 + (text.at(i).to_int() - 0x30)
      i = i + 1
    }
    exponent = if exponent_negative { -magnitude } else { magnitude }
  }
  let raw = digits.to_string()
  let mut start = 0
  while start < raw.length() && raw.at(start).to_int() == 0x30 {
    start = start + 1
  }
  if start == raw.length() {
    // Zero ignores its sign and its exponent.
    return Some("0")
  }
  let mut end = raw.length()
  while end > start && raw.at(end - 1).to_int() == 0x30 {
    end = end - 1
    exponent = exponent + 1
  }
  exponent = exponent - fraction_len
  let significant = raw.view(start_offset=start, end_offset=end).to_owned()
  let sign = if negative { "-" } else { "" }
  return Some("\{sign}\{significant}e\{exponent}")
}

///|
/// Whether a decoded number equals an expected numeric literal exactly.
fn number_matches(
  actual_repr : String?,
  actual : Double,
  expected : String,
) -> Bool {
  let actual_text = match actual_repr {
    Some(text) => text
    None => actual.to_string()
  }
  match (canonical_number(actual_text), canonical_number(expected)) {
    (Some(left), Some(right)) => left == right
    _ => false
  }
}

///|
/// Render a decoded scalar as the text a failure message shows.
fn render_scalar(json : Json) -> String {
  match json {
    Null => "null"
    True => "true"
    False => "false"
    String(s) => "\"" + s + "\""
    Number(n, repr~) =>
      match repr {
        Some(text) => text
        None => n.to_string()
      }
    Array(_) => "array"
    Object(_) => "object"
  }
}

///|
/// The type name and rendered text of an expected literal.
fn expected_render(literal : ExpectedLiteral) -> (String, String) {
  match literal {
    ExpectedInt(raw) => ("Int", raw)
    ExpectedFloat(raw) => ("Number", raw)
    ExpectedString(text) => ("String", "\"" + text + "\"")
    ExpectedBool(value) => ("Bool", if value { "true" } else { "false" })
    ExpectedNull => ("Null", "null")
  }
}

///|
/// The failure message for any mismatch, naming both types.
fn mismatch_message(
  path : String,
  literal : ExpectedLiteral,
  actual : Json,
) -> String {
  let (expected_type, expected_text) = expected_render(literal)
  return "json: \{label_of(path)}: expected \{expected_type} \{expected_text}, got \{type_name(actual)} \{render_scalar(actual)}"
}

///|
/// Compare an already decoded value against a typed expectation.
fn check_json_value(
  json : Json,
  path : String,
  expected : String,
  quoted : Bool,
) -> Result[Unit, String] {
  let value = match lookup_path(json, path) {
    Some(v) => v
    None => return Err("json: path \"\{path}\" not found in the response body")
  }
  let literal = classify_expected(expected, quoted)
  match value {
    Number(n, repr~) => {
      let integral = is_integral(n)
      match literal {
        ExpectedInt(raw) => {
          if !integral {
            return Err(mismatch_message(path, literal, value))
          }
          if number_matches(repr, n, raw) {
            return Ok(())
          }
          return Err(mismatch_message(path, literal, value))
        }
        ExpectedFloat(raw) => {
          if integral {
            return Err(mismatch_message(path, literal, value))
          }
          if number_matches(repr, n, raw) {
            return Ok(())
          }
          return Err(mismatch_message(path, literal, value))
        }
        _ => return Err(mismatch_message(path, literal, value))
      }
    }
    String(s) =>
      match literal {
        ExpectedString(raw) => {
          if s == raw {
            return Ok(())
          }
          return Err(mismatch_message(path, literal, value))
        }
        _ => Err(mismatch_message(path, literal, value))
      }
    True =>
      match literal {
        ExpectedBool(true) => Ok(())
        _ => Err(mismatch_message(path, literal, value))
      }
    False =>
      match literal {
        ExpectedBool(false) => Ok(())
        _ => Err(mismatch_message(path, literal, value))
      }
    Null =>
      match literal {
        ExpectedNull => Ok(())
        _ => Err(mismatch_message(path, literal, value))
      }
    _ =>
      Err("json: path \"\{path}\" is not a scalar value and cannot be compared")
  }
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
    match
      check_json_path_typed(
        body,
        check.path,
        check.expected,
        check.expected_quoted,
      ) {
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
