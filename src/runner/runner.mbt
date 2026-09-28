//
// MoonProbe - runner package
//
// The `runner` package is the execution engine that schedules and performs
// HTTP requests for every parsed `.probe` case.
//
// Planned responsibilities (landed in the dedicated runner feature commits):
//
//   - send HTTP requests with a configurable timeout
//   - sequential / parallel execution of cases
//   - variable extraction and context passing between cases
//   - aggregate per-case results into a result model consumed by reporters
//
// This module is intentionally empty in the scaffold commit and is filled in
// by the dedicated runner feature commits.