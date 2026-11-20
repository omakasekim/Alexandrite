# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-11-20

### Added
- Regex syntax: capture-free groups, nested alternation, bounded quantifiers `{m}`, `{m,}`, `{m,n}`, negated and escaped character classes, `^`/`$` anchors, and inline flags `(?i)` and `(?s)`.
- Hopcroft DFA minimization with alphabet equivalence-class compression.
- Language equivalence checking (Hopcroft-Karp union-find) that returns the shortest distinguishing string as a counterexample.
- Empty-language and finite-language decision procedures.
- Structured `CompileError` diagnostics with byte offsets and resource limits on states and pattern depth.
- `CompiledLexer`: comptime single-pass maximal-munch lexer with rule priority, line and column tracking, and rejection of empty-matching rules.
- CLI subcommands `find --all`, `dump --dot|--json`, `equiv`, `lex` and `bench`, all with `--json` output and `-i` / `-s` flags.
- WASM exports for flags-aware compile, multi-match iteration (`find_from`, `scan_count`, `last_match_end`), equivalence class introspection, language emptiness and finiteness, and last-error reporting. All 0.1.0 exports keep their signatures.
- Reusable `alexandrite` Zig module via `src/root.zig`.
- Property tests: minimization preserves the language, and NFA-derived DFAs agree with a brute-force reference over every binary string up to a fixed length.

## [0.1.0] - 2026-11-08

### Added
- Initial release of Alexandrite: Compile-Time & Runtime DFA Regular Expression and Lexer Engine in Zig.
- Compile-time minimal DFA transition matrix construction embedding tables into .rodata.
- Runtime DFA construction for dynamic patterns without heap allocations during matching.
- Lexer engine supporting token rule registration and stream tokenization.
- Freestanding WebAssembly compilation target (wasm32-freestanding) with direct buffer exports.
- Benchmark and validation test suite with sub-100 MB/s scanning throughput.
