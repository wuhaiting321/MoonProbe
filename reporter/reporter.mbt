/// MoonProbe - reporter
///
/// Renders the outcome of a run as a readable console report.
///
/// The output is plain text with a little ANSI colour, and every case is also
/// tagged `[PASS]` / `[FAIL]` so that the report stays readable both in a
/// terminal that understands escape sequences and in a log file that does not.

/// ANSI escape sequence that clears the highlighting.
const ANSI_RESET : String = "\u{1b}[0m"

/// ANSI escape sequence for the "passed" highlight.
const ANSI_GREEN : String = "\u{1b}[32m"

/// ANSI escape sequence for the "failed" highlight.
const ANSI_RED : String = "\u{1b}[31m"

/// The summary line printed after the per-case section.
///
/// It reports the three counts a CI log is scanned for, plus the wall-clock
/// duration of the run.
fn summary_line(total : Int, passed : Int, elapsed_ms : UInt64) -> String {
  return "Summary: \{total} total, \{passed} passed, \{total - passed} failed in \{elapsed_ms} ms"
}

/// Whether every case of the run passed.
pub fn all_passed(results : Array[@runner.TestResult]) -> Bool {
  for result in results {
    if !result.passed() {
      return false
    }
  }
  return true
}

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
  elapsed_ms : UInt64
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