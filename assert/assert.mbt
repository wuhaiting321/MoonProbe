/// MoonProbe - assert
///
/// The assertion engine compares a response against the `expect:` block of a
/// parsed `.probe` case.
///
/// A check reports a failure as text instead of raising, so that one mismatching
/// field never hides the others: `check_expect` runs the whole block and hands
/// back every message it collected.

/// Compare the response status against the expected one.
pub fn check_status(expected : Int, actual : Int) -> Result[Unit, String] {
  if expected == actual {
    return Ok(())
  }
  return Err("status: expected \{expected}, got \{actual}")
}

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

/// Walk a dotted path such as `data.count` through the JSON objects of a
/// response body.
///
/// Returns `None` as soon as a segment is absent or the value reached on the
/// way is not an object.
fn lookup_path(json : Json, path : String) -> Json? {
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

/// Compare one JSON field, addressed by a dotted path, against the text written
/// in the `.probe` expectation.
pub fn check_json_path(
  body : String,
  path : String,
  expected : String
) -> Result[Unit, String] {
  let json = try {
    @json.parse(body)
  } catch {
    err => return Err("json: response body is not valid json (\{err})")
  }
  let value = match lookup_path(json, path) {
    Some(v) => v
    None => return Err("json: path \"\{path}\" not found in the response body")
  }
  let actual = match json_text(value) {
    Some(text) => text
    None =>
      return Err(
        "json: path \"\{path}\" is not a scalar value and cannot be compared",
      )
  }
  if actual == expected {
    return Ok(())
  }
  return Err("json: \{path}: expected \"\{expected}\", got \"\{actual}\"")
}

/// Run every expectation of an `expect:` block against a response.
///
/// Returns the failure messages in declaration order; an empty array means the
/// case passed.
pub fn check_expect(
  expect : @parser.Expect,
  status : Int,
  body : String
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
  return failures
}