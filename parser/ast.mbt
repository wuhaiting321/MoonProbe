/// MoonProbe - parser package
///
/// Provides the Abstract Syntax Tree (AST) types that represent a parsed
/// `.probe` test suite. The AST is deliberately small and data-only so that
/// the runner and reporter never depend on lexical details.

/// A key/value pair used for HTTP headers, query parameters and JSON checks.
pub struct Pair {
  key : String
  value : String
}

/// The `request:` block of a single `.probe` case.
pub struct Request {
  http_method : String
  url : String
  headers : Array[Pair]
  query : Array[Pair]
  /// Optional raw request body. `None` means no body was declared.
  body : Option[String]
}

/// A single expected value at a dotted JSON path, e.g. `data.count -> 3`.
pub struct JsonCheck {
  path : String
  expected : String
}

/// A variable extraction performed after a case succeeds, e.g.
/// `set: token = data.token` binds the value found at the JSON path
/// `data.token` to the variable name `token`.
pub struct SetSpec {
  name : String
  path : String
}

/// The `expect:` block of a single `.probe` case.
pub struct Expect {
  /// Expected HTTP status code. `None` means it was not declared.
  status : Option[Int]
  checks : Array[JsonCheck]
  /// Variables extracted from the response body, in declaration order.
  sets : Array[SetSpec]
}

/// One complete `.probe` test case: a request plus its expectations.
pub struct Case {
  name : String
  request : Request
  expect : Expect
}

/// A whole `.probe` test suite made of one or more cases.
pub struct Suite {
  cases : Array[Case]
}