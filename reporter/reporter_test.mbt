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