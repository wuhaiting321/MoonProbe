/// MoonProbe - reporter
///
/// Renders the outcome of a run, either as a readable console report or as a
/// JUnit XML file for a CI pipeline.
///
/// The console output is plain text with a little ANSI colour, and every case is
/// also tagged `[PASS]` / `[FAIL]` so that the report stays readable both in a
/// terminal that understands escape sequences and in a log file that does not.

///|
/// ANSI escape sequence that clears the highlighting.
const ANSI_RESET : String = "\u{1b}[0m"

///|
/// ANSI escape sequence for the "passed" highlight.
const ANSI_GREEN : String = "\u{1b}[32m"

///|
/// ANSI escape sequence for the "failed" highlight.
const ANSI_RED : String = "\u{1b}[31m"

///|
/// The summary line printed after the per-case section.
///
/// It reports the three counts a CI log is scanned for, plus the wall-clock
/// duration of the run.
fn summary_line(total : Int, passed : Int, elapsed_ms : UInt64) -> String {
  return "Summary: \{total} total, \{passed} passed, \{total - passed} failed in \{elapsed_ms} ms"
}

///|
/// Whether every case of the run passed.
pub fn all_passed(results : Array[@runner.TestResult]) -> Bool {
  for result in results {
    if !result.passed() {
      return false
    }
  }
  return true
}

///|
/// Print the console report of a finished run.
///
/// `elapsed_ms` is the wall-clock duration of the whole run, measured by the
/// caller so that this package stays free of any platform clock.
///
/// Each failing case is followed by the assertion messages the engine collected,
/// one per line, so a log shows both which expectation broke and what the server
/// actually returned.
pub fn print_report(
  results : Array[@runner.TestResult],
  elapsed_ms : UInt64,
) -> Unit {
  let mut passed = 0
  for result in results {
    if result.passed() {
      passed = passed + 1
      println("\{ANSI_GREEN}[PASS]\{ANSI_RESET} \{result.name}")
    } else {
      println("\{ANSI_RED}[FAIL]\{ANSI_RESET} \{result.name}")
      for failure in result.failures {
        println("       \{failure}")
      }
    }
  }
  println("")
  println(summary_line(results.length(), passed, elapsed_ms))
  if all_passed(results) {
    println("\{ANSI_GREEN}Result: PASSED\{ANSI_RESET}")
  } else {
    println("\{ANSI_RED}Result: FAILED\{ANSI_RESET}")
  }
}

///|
/// Format a millisecond count as the seconds value JUnit expects, e.g. `1.234`.
fn seconds(ms : UInt64) -> String {
  let whole : String = "\{ms / 1000}"
  let frac : String = "\{ms % 1000}"
  return whole + "." + frac.pad_start(3, '0')
}

///|
/// Escape the five XML metacharacters so that a case name or a failure message
/// can be embedded in the report without breaking it.
fn xml_escape(text : String) -> String {
  let buf = StringBuilder()
  for c in text {
    if c == '&' {
      buf.write_string("&amp;")
    } else if c == '<' {
      buf.write_string("&lt;")
    } else if c == '>' {
      buf.write_string("&gt;")
    } else if c == '"' {
      buf.write_string("&quot;")
    } else if c == '\'' {
      buf.write_string("&apos;")
    } else {
      buf.write_char(c)
    }
  }
  return buf.to_string()
}

///|
/// Render a finished run as a JUnit XML document.
///
/// The document follows the layout Jenkins and GitHub Actions understand: one
/// `<testsuite>` holding a `<testcase>` per `.probe` case, with the assertion
/// messages of a failing case nested in `<failure>` elements. The caller decides
/// where to write it.
pub fn to_junit_xml(
  results : Array[@runner.TestResult],
  elapsed_ms : UInt64,
) -> String {
  let total : String = "\{results.length()}"
  let mut failed = 0
  for result in results {
    if !result.passed() {
      failed = failed + 1
    }
  }
  let failed_s : String = "\{failed}"
  let time = seconds(elapsed_ms)
  let counts = "tests=\"" +
    total +
    "\" failures=\"" +
    failed_s +
    "\" errors=\"0\" time=\"" +
    time +
    "\""
  let buf = StringBuilder()
  buf.write_string("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
  buf.write_string("<testsuites name=\"MoonProbe\" " + counts + ">\n")
  buf.write_string("  <testsuite name=\"MoonProbe\" " + counts + ">\n")
  for result in results {
    let attrs = " name=\"" +
      xml_escape(result.name) +
      "\" classname=\"MoonProbe\" time=\"" +
      seconds(result.elapsed_ms) +
      "\""
    if result.passed() {
      buf.write_string("    <testcase" + attrs + "/>\n")
    } else {
      buf.write_string("    <testcase" + attrs + ">\n")
      for failure in result.failures {
        let message = xml_escape(failure)
        buf.write_string(
          "      <failure message=\"" +
          message +
          "\">" +
          message +
          "</failure>\n",
        )
      }
      buf.write_string("    </testcase>\n")
    }
  }
  buf.write_string("  </testsuite>\n")
  buf.write_string("</testsuites>\n")
  return buf.to_string()
}
