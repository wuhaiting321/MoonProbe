//
// MoonProbe - parser package
//
// The `parser` package is responsible for turning declarative `.probe`
// text files into an internal Abstract Syntax Tree (AST).
//
// It will be split into three modules over the course of the project:
//
//   - lexer.mbt  : tokenize raw `.probe` source text
//   - ast.mbt    : define the AST node types representing a test suite
//   - parser.mbt : recursive-descent / state-machine parser building the AST
//
// Only the top-level `parse` entrypoint is exported so callers (the runner
// and the CLI) never depend on the lexical details.
//
// The module is intentionally left empty in this initial scaffold commit;
// the lexer and AST definitions land in the dedicated parser feature commits.