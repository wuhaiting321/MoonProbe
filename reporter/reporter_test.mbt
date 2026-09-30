///|
/// MoonProbe - reporter tests
///
/// The console report is exercised end to end through the CLI; what is checked
/// here is the JUnit XML document, whose shape a CI server depends on.
test "to_junit_xml renders the document skeleton of a run without results" {
  let source =
    #|name: "skeleton"
    #|request:
    #|  url: "https://example.com"
    #|expect:
    #|  status: 200
    #|
  // The suite parses on every backend, but executing it needs a transport, so
  // the skeleton is rendered here from an empty result list.
  let suite = match @parser.parse(source) {
    Ok(s) => s
    Err(msg) => fail("fixture should parse: \{msg}")
  }
  @test.assert_eq(suite.cases.length(), 1)
  let results : Array[@runner.TestResult] = []
  let xml = @reporter.to_junit_xml(results, 1234)
  @test.assert_eq(
    xml.contains("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"),
    true,
  )
  @test.assert_eq(
    xml.contains(
      "<testsuites name=\"MoonProbe\" tests=\"0\" failures=\"0\" errors=\"0\" time=\"1.234\">",
    ),
    true,
  )
  @test.assert_eq(xml.contains("</testsuite>"), true)
  @test.assert_eq(xml.contains("</testsuites>"), true)
}

///|
#cfg(target="js")
test "to_junit_xml embeds a real case and its assertion failure" {
  let source =
    #|name: "reported case"
    #|request:
    #|  url: "https://example.com"
    #|expect:
    #|  status: 404
    #|
  let suite = match @parser.parse(source) {
    Ok(s) => s
    Err(msg) => fail("fixture should parse: \{msg}")
  }
  let results = match @runner.run_suite(suite) {
    Ok(r) => r
    Err(msg) => fail("suite should run: \{msg}")
  }
  let xml = @reporter.to_junit_xml(results, 2000)
  @test.assert_eq(xml.contains("tests=\"1\" failures=\"1\""), true)
  @test.assert_eq(
    xml.contains("<testcase name=\"reported case\" classname=\"MoonProbe\""),
    true,
  )
  @test.assert_eq(xml.contains("<failure message="), true)
  @test.assert_eq(xml.contains("</testcase>"), true)
  @test.assert_eq(xml.contains("time=\"2.000\""), true)
}

///|
/// The whole pipeline in one test: a `.probe` source is parsed, executed against
/// a scripted transport — config merge, variable injection, hooks, assertions —
/// and rendered as JUnit XML. It is the chain the CLI performs, with the network
/// replaced by a function so that it runs on every backend.
test "the pipeline runs a parsed suite end to end and reports it" {
  let source =
    #|config:
    #|  base_url: "https://api.test"
    #|  global_headers:
    #|    Accept: "application/json"
    #|before_each:
    #|  name: "sign in"
    #|  request:
    #|    method: POST
    #|    url: "/login"
    #|  expect:
    #|    status: 200
    #|    set: token = header.X-Token
    #|name: "list users"
    #|request:
    #|  url: "/users"
    #|  headers:
    #|    Authorization: "Bearer {{token}}"
    #|expect:
    #|  status: 200
    #|  json:
    #|    data.count: 2
    #|name: "missing endpoint"
    #|request:
    #|  url: "/broken"
    #|expect:
    #|  status: 200
    #|
  let seen : Array[String] = []
  let transport : @runner.Transport = fn(
    verb : String,
    url : String,
    headers : String,
    _body : String,
    _timeout_ms : Int,
  ) -> Result[(Int, Array[(String, String)], String), String] {
    seen.push("\{verb} \{url} | \{headers}")
    if url.contains("/login") {
      return Ok((200, [("X-Token", "tok-7")], ""))
    }
    if url.contains("/users") {
      return Ok((200, [], "{\"data\":{\"count\":2}}"))
    }
    return Ok((404, [], ""))
  }
  let suite = match @parser.parse(source) {
    Ok(s) => s
    Err(msg) => fail("fixture should parse: \{msg}")
  }
  let results = match @runner.run_suite_with(transport, suite) {
    Ok(r) => r
    Err(msg) => fail("suite should run: \{msg}")
  }
  @test.assert_eq(results.length(), 2)
  @test.assert_eq(results[0].passed(), true)
  @test.assert_eq(results[1].passed(), false)

  // The config reached the URL join and the global headers, and the token the
  // setup step extracted reached the case that asked for it. The sign-in step
  // belongs to the suite, so it runs before each of the two cases.
  @test.assert_eq(seen.length(), 4)
  @test.assert_eq(seen[0].contains("POST https://api.test/login"), true)
  @test.assert_eq(seen[0].contains("Accept: application/json"), true)
  @test.assert_eq(seen[1].contains("GET https://api.test/users"), true)
  @test.assert_eq(seen[1].contains("Authorization: Bearer tok-7"), true)
  @test.assert_eq(seen[2].contains("POST https://api.test/login"), true)
  @test.assert_eq(seen[3].contains("GET https://api.test/broken"), true)

  let xml = @reporter.to_junit_xml(results, 1500)
  @test.assert_eq(xml.contains("tests=\"2\" failures=\"1\""), true)
  @test.assert_eq(xml.contains("time=\"1.500\""), true)
  @test.assert_eq(xml.contains("<testcase name=\"list users\""), true)
  @test.assert_eq(xml.contains("<testcase name=\"missing endpoint\""), true)
  @test.assert_eq(
    xml.contains("<failure message=\"status: expected 200, got 404\""),
    true,
  )
}
