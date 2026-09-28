# MoonProbe

A pure-MoonBit declarative API test runner for the **MoonBit Hackathon 2026 (September edition)**.

MoonProbe parses human-readable `.probe` text cases into an AST, sends the
declared HTTP requests, asserts on status codes and JSON response bodies, and
finally emits both a console report and a JUnit XML report for CI integration.

> Status: initial skeleton. The full proposal, usage guide and MVP instructions
> are finalized in a later documentation commit.

## Roadmap (planned)

- `src/parser`  : `.probe` lexer, AST and parser
- `src/runner`  : async HTTP executor with timeout and variable context
- `src/assert`  : status-code and JSON body assertion engine
- `src/reporter`: console and JUnit XML report generation
- `src/cli`     : native command-line entrypoint

## License

Distributed under the [Apache License 2.0](./LICENSE).