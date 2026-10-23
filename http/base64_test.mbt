/// MoonProbe - base64 tests
///
/// The bridge between MoonBit and the socket speaks base64 so that a binary
/// response survives the string boundary. These tests fix the decoder's
/// contract: correct bytes on valid input, an explicit error on anything else.

///|
test "decode a padded group" {
  let bytes = match @http.decode_base64("aGk=") {
    Ok(value) => value
    Err(msg) => fail("base64 should decode: \{msg}")
  }
  @test.assert_eq(bytes, b"hi")
}

///|
test "decode an unpadded group" {
  let bytes = match @http.decode_base64("aGk") {
    Ok(value) => value
    Err(msg) => fail("base64 should decode: \{msg}")
  }
  @test.assert_eq(bytes, b"hi")
}

///|
test "decode every byte value of a small alphabet sample" {
  let bytes = match @http.decode_base64("AAECAwQ=") {
    Ok(value) => value
    Err(msg) => fail("base64 should decode: \{msg}")
  }
  @test.assert_eq(bytes, b"\x00\x01\x02\x03\x04")
}

///|
test "decode the empty string as empty bytes" {
  let bytes = match @http.decode_base64("") {
    Ok(value) => value
    Err(msg) => fail("base64 should decode: \{msg}")
  }
  @test.assert_eq(bytes.length(), 0)
}

///|
test "decode a single padded character group" {
  let bytes = match @http.decode_base64("aA==") {
    Ok(value) => value
    Err(msg) => fail("base64 should decode: \{msg}")
  }
  @test.assert_eq(bytes, b"h")
}

///|
test "whitespace is rejected" {
  match @http.decode_base64("aG k=") {
    Ok(_) => fail("whitespace must not decode")
    Err(msg) => @test.assert_eq(msg.has_prefix("invalid base64"), true)
  }
}

///|
test "a character outside the alphabet is rejected" {
  match @http.decode_base64("aGk*") {
    Ok(_) => fail("a foreign character must not decode")
    Err(msg) => @test.assert_eq(msg.has_prefix("invalid base64"), true)
  }
}

///|
test "data after padding is rejected" {
  match @http.decode_base64("aG=k") {
    Ok(_) => fail("data after padding must not decode")
    Err(msg) => @test.assert_eq(msg, "invalid base64: data after padding")
  }
}

///|
test "too much padding is rejected" {
  match @http.decode_base64("a===") {
    Ok(_) => fail("triple padding must not decode")
    Err(msg) => @test.assert_eq(msg, "invalid base64: too much padding")
  }
}

///|
test "a partial group is rejected" {
  match @http.decode_base64("a") {
    Ok(_) => fail("a one-character group must not decode")
    Err(msg) => @test.assert_eq(msg, "invalid base64: a partial group")
  }
}

///|
test "non-zero trailing bits are rejected" {
  // `aGl` differs from `aGk` only in the two bits that should be zero.
  match @http.decode_base64("aGl") {
    Ok(_) => fail("non-zero trailing bits must not decode")
    Err(msg) => @test.assert_eq(msg, "invalid base64: non-zero trailing bits")
  }
}

///|
test "the url-safe alphabet is rejected" {
  match @http.decode_base64("aG-_") {
    Ok(_) => fail("the url-safe alphabet is not this decoder's input")
    Err(msg) => @test.assert_eq(msg.has_prefix("invalid base64"), true)
  }
}
