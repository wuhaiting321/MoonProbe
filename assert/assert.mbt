//
// MoonProbe - assert package
//
// The `assert` package provides the assertion engine that compares an actual
// HTTP response against the expectations declared in a `.probe` case.
//
// Planned capabilities (landed in the dedicated assert feature commits):
//
//   - HTTP status code assertions (exact, ranges)
//   - structured JSON body assertions (deep equality, path / key
//     extraction, type and value matching)
//   - header assertions
//   - support for the JUnit XML report mapping of assertion results
//
// This module is intentionally empty in the scaffold commit. The assertion
// engine is implemented in a later feature commit.