/// MoonProbe - parser package
///
/// Provides the Abstract Syntax Tree (AST) types that represent a parsed
/// `.probe` test suite. The AST is deliberately small and data-only so that
/// the runner and reporter never depend on lexical details.

///|
/// A key/value pair used for HTTP headers, query parameters and JSON checks.
pub struct Pair {
  key : String
  value : String
}

///|
/// The `request:` block of a single `.probe` case.
pub struct Request {
  http_method : String
  url : String
  headers : Array[Pair]
  query : Array[Pair]
  /// Optional raw request body. `None` means no body was declared.
  body : String?
  /// Case-level timeout in milliseconds, which wins over the config block's
  /// `global_timeout`. `None` means the case did not declare one.
  timeout_ms : Int?
  /// How many extra attempts this request may have, which wins over the config
  /// block's `retry`. `None` means the case did not declare its own budget.
  retry_count : Int?
}

///|
/// A single expected value at a dotted JSON path, e.g. `data.count -> 3`.
pub struct JsonCheck {
  path : String
  expected : String
}

///|
/// Where a `set:` directive reads the value it binds.
///
/// The source is written as a prefix on the path, so
/// `set: token = header.X-Token` reads a response header while
/// `set: token = cookie.session` reads a cookie the server set. A path without a
/// prefix means the response body.
pub enum SetSource {
  FromBody
  FromHeader
  FromCookie
} derive(Eq)

///|
/// A variable extraction performed after a case succeeds, e.g.
/// `set: token = data.token` binds the value found at the JSON path
/// `data.token` to the variable name `token`.
pub struct SetSpec {
  name : String
  /// Where the value is read from: body, response header or cookie.
  source : SetSource
  /// Dotted JSON path, header name or cookie name, depending on `source`.
  path : String
}

///|
/// The suite-wide `config:` block that sits at the top of a `.probe` file.
///
/// Everything here is a default: a case may still declare its own URL, headers
/// and timeout, and what it declares wins over what the config block declares.
pub struct Config {
  /// Absolute URL a relative `url:` is resolved against. `None` means relative
  /// URLs are rejected.
  base_url : String?
  /// Headers sent with every case, unless a case declares the same header.
  global_headers : Array[Pair]
  /// Per-request timeout for every case, in milliseconds.
  global_timeout_ms : Int?
  /// Retry budget for every case, overridden by a case's own `retry:`.
  retry_count : Int?
}

///|
/// The empty config: no base URL, no global headers, no global timeout.
///
/// This is what a `.probe` file that declares no `config:` block parses into,
/// and it is what a caller that drives the runner by hand starts from.
pub fn default_config() -> Config {
  return {
    base_url: None,
    global_headers: [],
    global_timeout_ms: None,
    retry_count: None,
  }
}

///|
/// Whether the config block declares nothing at all.
pub fn Config::is_empty(self : Config) -> Bool {
  match (self.base_url, self.global_timeout_ms, self.retry_count) {
    (None, None, None) => self.global_headers.length() == 0
    _ => false
  }
}

///|
/// The JSON type a value is expected to hold.
///
/// `TypeInt` and `TypeNumber` are deliberately distinct: a number that carries
/// no fractional part is an `Int`, while `1.5` is a `Number`. That is what lets
/// a suite catch an API that quietly started returning a float where an integer
/// used to be.
pub enum JsonType {
  TypeString
  TypeInt
  TypeNumber
  TypeBool
  TypeNull
  TypeObject
  TypeArray
} derive(Eq)

///|
/// The human-readable name of a JSON type: what a `.probe` author writes in a
/// `type:` or `schema:` expectation, and what a failure message reports.
pub fn JsonType::label(self : JsonType) -> String {
  match self {
    TypeString => "String"
    TypeInt => "Int"
    TypeNumber => "Number"
    TypeBool => "Bool"
    TypeNull => "Null"
    TypeObject => "Object"
    TypeArray => "Array"
  }
}

///|
/// A substring the raw response body must contain, e.g.
/// `contains: "ok"` or `contains_ci: "OK"`.
pub struct ContainsCheck {
  /// The text to look for.
  needle : String
  /// When true the comparison folds ASCII case, so `OK` also matches `ok`.
  ignore_case : Bool
}

///|
/// The exact number of elements a JSON array must have, e.g.
/// `data.items: 3` under a `length:` block.
pub struct LengthCheck {
  /// Dotted JSON path of the array. An empty path addresses the body root.
  path : String
  size : Int
}

///|
/// The JSON type a field must hold, e.g. `code: Int` under a `type:` block.
pub struct TypeCheck {
  /// Dotted JSON path of the field. An empty path addresses the body root.
  path : String
  expected : JsonType
}

///|
/// A budget on how long the request itself may take, e.g.
/// `duration_ms < 500`.
pub struct DurationCheck {
  /// One of `<`, `<=`, `>`, `>=`, `==`, `!=`.
  op : String
  /// The bound, in milliseconds. Never negative: the parser rejects that.
  limit_ms : Int
}

///|
/// One field of a `schema:` block, describing the shape a response must have.
///
/// A field is optional unless it is written with a trailing `!`, and an
/// `object` field may declare its own children one indentation level deeper,
/// which is how a nested structure is validated.
pub struct SchemaField {
  /// Key this field is looked up under.
  name : String
  /// Whether the key must be present.
  required : Bool
  field_type : JsonType
  /// Nested fields of an `object` field; empty for every other type.
  children : Array[SchemaField]
}

///|
/// The `expect:` block of a single `.probe` case.
pub struct Expect {
  /// Expected HTTP status code. `None` means it was not declared.
  status : Int?
  checks : Array[JsonCheck]
  /// Variables extracted from the response body, in declaration order.
  sets : Array[SetSpec]
  /// Substrings the raw body must contain, in declaration order.
  contains : Array[ContainsCheck]
  /// Element counts required of JSON arrays.
  lengths : Array[LengthCheck]
  /// JSON types required of fields.
  types : Array[TypeCheck]
  /// Optional budget on the request duration.
  duration : DurationCheck?
  /// Structure the body must satisfy. An empty array means no schema was
  /// declared.
  schema : Array[SchemaField]
}

///|
/// One complete `.probe` test case: a request plus its expectations.
pub struct Case {
  name : String
  request : Request
  expect : Expect
  /// Steps to run before this case, declared by the case itself.
  before_each : Array[Case]
  /// Steps to run after this case, declared by the case itself.
  after_each : Array[Case]
}

///|
/// A whole `.probe` test suite: its suite-wide config and its cases.
pub struct Suite {
  /// The `config:` block, or the empty config when the file declares none.
  config : Config
  cases : Array[Case]
  /// Steps run before every case of the file.
  before_each : Array[Case]
  /// Steps run after every case of the file, even when the case failed.
  after_each : Array[Case]
}
