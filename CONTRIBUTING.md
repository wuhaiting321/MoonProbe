# Contributing to MoonProbe

Thanks for taking the time to contribute. This document describes how to build,
test and extend MoonProbe.

## Prerequisites

| Tool | Version used by the project | Notes |
| --- | --- | --- |
| MoonBit toolchain (`moon`) | `0.1.20260915` | Install from <https://www.moonbitlang.cn/download> |
| Node.js | `v24` | Only needed to run the CLI / real HTTP requests (`js` target) |
| `curl` | 8.x | The `js` transport shells out to it; it ships with Windows and most Linux images |

## Getting started

```bash
git clone <this repository>
cd MoonProbe
moon check --target wasm-gc
```

## Build, check and test

The unit tests are backend independent and run on `wasm-gc`:

```bash
moon check --target wasm-gc
moon test  --target wasm-gc
moon build --target wasm-gc
```

The network tests and the CLI need the `js` target, which runs on Node.js:

```bash
moon check --target js
moon test  --target js
moon run cli --target js -- examples/auth_chain.probe
```

CI runs exactly `moon check --target wasm-gc`, `moon test --target wasm-gc` and
`moon build --target wasm-gc`, so a change that passes locally on `wasm-gc`
passes in CI too.

## Layout

| Package | Responsibility |
| --- | --- |
| `parser` | `.probe` lexer, AST and parser |
| `runner` | request resolution (`{{var}}` interpolation), HTTP transport, suite execution |
| `assert` | status code and JSON body assertions |
| `reporter` | console report and JUnit XML generation |
| `cli` | command line entry point, file system FFI |
| `examples` | runnable `.probe` suites |

## Coding conventions

- Keep the MoonBit sources free of compiler warnings: the project builds with
  zero warnings on both `wasm-gc` and `js`.
- Prefer current APIs; deprecated ones such as `Char::from_int`, `not(x)` and
  `String::to_bytes` are rejected in review.
- Comments and documentation strings are written in English, in whole
  sentences, and explain *why* rather than *what*.
- Platform-specific code is isolated behind `#cfg(target="js")` and
  `#cfg(not(target="js"))`; shared logic must stay FFI-free so that it remains
  testable on every backend.
- Every new function that encodes a decision (a parser rule, an assertion rule,
  an interpolation rule) comes with at least one unit test, using an inline
  fixture in the matching `*_test.mbt` file.

## Commits

Commits follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(runner): add variable extraction and context passing between cases
fix(runner): report the underlying transport error
test(parser): add unit tests for parser with valid/invalid fixtures
docs: finalize the proposal in the README
ci: add github actions for moon test and build validation
chore: add license, contributing guide and code of conduct
```

Rules:

- One logical change per commit; the module must compile and all tests must pass
  on the commit itself.
- The message body, when present, explains the motivation, not the diff.

## Pull requests

1. Fork the repository and create a topic branch.
2. Add the change together with its tests and, when the `.probe` grammar or the
   CLI changes, the matching README section.
3. Run `moon check --target wasm-gc`, `moon test --target wasm-gc` and
   `moon check --target js` before pushing.
4. Describe in the pull request what was changed and how it was verified.

By participating you agree to abide by the [Code of Conduct](./CODE_OF_CONDUCT.md).