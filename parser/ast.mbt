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
}

///|
/// A single expected value at a dotted JSON path, e.g. `data.count -> 3`.
pub struct JsonCheck {
  path : String
  expected : String
}

///|
/// A variable extraction performed after a case succeeds, e.g.
/// `set: token = data.token` binds the value found at the JSON path
/// `data.token` to the variable name `token`.
pub struct SetSpec {
  name : String
  path : String
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
}

///|
/// A whole `.probe` test suite made of one or more cases.
pub struct Suite {
  cases : Array[Case]
}
