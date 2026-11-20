pub const compiler = @import("compiler.zig");
pub const dfa = @import("dfa.zig");
pub const lexer = @import("lexer.zig");
pub const wasm = @import("wasm.zig");

pub const Dfa = dfa.Dfa;
pub const Span = dfa.Span;
pub const MatchIterator = dfa.MatchIterator;
pub const CompileError = compiler.CompileError;
pub const CompileOptions = compiler.CompileOptions;

pub const Lexer = lexer.Lexer;
pub const CompiledLexer = lexer.CompiledLexer;
pub const LexerError = lexer.LexerError;
pub const Token = lexer.Token;
pub const TokenType = lexer.TokenType;
pub const RuleSpec = lexer.RuleSpec;

test {
    _ = @import("compiler.zig");
    _ = @import("dfa.zig");
    _ = @import("lexer.zig");
    _ = @import("wasm.zig");
}
