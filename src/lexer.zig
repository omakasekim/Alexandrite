const std = @import("std");
const dfa_mod = @import("dfa.zig");
const compiler = @import("compiler.zig");
const Dfa = dfa_mod.Dfa;

pub const TokenType = enum(u16) {
    identifier = 1,
    number = 2,
    string_literal = 3,
    operator = 4,
    whitespace = 5,
    comment = 6,
    keyword = 7,
    unknown = 8,
    punctuation = 9,
};

pub const Token = struct {
    token_type: TokenType,
    start: usize,
    end: usize,
    line: usize,
    column: usize,

    pub fn lexeme(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

pub const LexerError = compiler.CompileError || error{
    TooManyRules,
    EmptyRules,
    EmptyLexerRule,
};

pub const LexerRule = struct {
    token_type: TokenType,
    dfa: Dfa,
};

pub const RuleSpec = struct {
    token_type: TokenType,
    pattern: []const u8,
    skip: bool = false,
    options: compiler.CompileOptions = .{},
};

pub const AcceptAction = struct {
    token_type: TokenType,
    skip: bool = false,
};

fn advancePosition(slice: []const u8, line: *usize, col: *usize) void {
    for (slice) |b| {
        if (b == '\n') {
            line.* += 1;
            col.* = 1;
        } else {
            col.* += 1;
        }
    }
}

pub const Lexer = struct {
    rules: [8]?LexerRule,
    rule_count: usize,

    pub fn init() Lexer {
        return .{
            .rules = @splat(null),
            .rule_count = 0,
        };
    }

    pub fn addRule(self: *Lexer, token_type: TokenType, pattern: []const u8) void {
        if (self.rule_count >= 8) return;
        self.rules[self.rule_count] = LexerRule{
            .token_type = token_type,
            .dfa = Dfa.compileRuntime(pattern),
        };
        self.rule_count += 1;
    }

    pub fn addRuleChecked(self: *Lexer, token_type: TokenType, pattern: []const u8) LexerError!void {
        if (self.rule_count >= 8) return error.TooManyRules;
        const compiled = try Dfa.compileChecked(pattern);
        if (compiled.accepting[dfa_mod.START_STATE]) return error.EmptyLexerRule;
        self.rules[self.rule_count] = LexerRule{
            .token_type = token_type,
            .dfa = compiled,
        };
        self.rule_count += 1;
    }

    pub fn addDfaRule(self: *Lexer, token_type: TokenType, dfa: Dfa) LexerError!void {
        if (self.rule_count >= 8) return error.TooManyRules;
        if (dfa.accepting[dfa_mod.START_STATE]) return error.EmptyLexerRule;
        self.rules[self.rule_count] = LexerRule{
            .token_type = token_type,
            .dfa = dfa,
        };
        self.rule_count += 1;
    }

    fn hasWhitespaceRule(self: *const Lexer) bool {
        for (0..self.rule_count) |r| {
            if (self.rules[r]) |rule| {
                if (rule.token_type == .whitespace) return true;
            }
        }
        return false;
    }

    pub fn tokenize(self: *const Lexer, input: []const u8, out_tokens: []Token) usize {
        var token_idx: usize = 0;
        var cursor: usize = 0;
        var line: usize = 1;
        var col: usize = 1;
        const explicit_ws = self.hasWhitespaceRule();

        while (cursor < input.len and token_idx < out_tokens.len) {
            // Skip ASCII whitespace automatically unless caller registered an explicit .whitespace rule
            if (!explicit_ws and (input[cursor] == ' ' or input[cursor] == '\t' or input[cursor] == '\r' or input[cursor] == '\n')) {
                advancePosition(input[cursor .. cursor + 1], &line, &col);
                cursor += 1;
                continue;
            }

            var best_len: usize = 0;
            var best_type: TokenType = .unknown;

            for (0..self.rule_count) |r| {
                if (self.rules[r]) |rule| {
                    var state: u16 = dfa_mod.START_STATE;
                    var match_len: usize = 0;

                    for (input[cursor..], 0..) |b, offset| {
                        state = rule.dfa.table[state][b];
                        if (state == dfa_mod.DEAD_STATE) break;
                        if (rule.dfa.accepting[state]) {
                            match_len = offset + 1;
                        }
                    }

                    if (match_len > best_len) {
                        best_len = match_len;
                        best_type = rule.token_type;
                    }
                }
            }

            if (best_len > 0) {
                out_tokens[token_idx] = Token{
                    .token_type = best_type,
                    .start = cursor,
                    .end = cursor + best_len,
                    .line = line,
                    .column = col,
                };
                token_idx += 1;
                advancePosition(input[cursor .. cursor + best_len], &line, &col);
                cursor += best_len;
            } else {
                // Unknown single byte fallback
                out_tokens[token_idx] = Token{
                    .token_type = .unknown,
                    .start = cursor,
                    .end = cursor + 1,
                    .line = line,
                    .column = col,
                };
                token_idx += 1;
                advancePosition(input[cursor .. cursor + 1], &line, &col);
                cursor += 1;
            }
        }

        return token_idx;
    }
};

/// Single-pass minimized multi-rule DFA lexer.
/// Compiles all rules into a single transition matrix with maximal-munch
/// scanning, first-rule tie-breaking priority, skip actions, and exact
/// multi-line (line, column) tracking. Supports both `comptime` and runtime compilation.
pub const CompiledLexer = struct {
    num_states: u16,
    table: [dfa_mod.MAX_STATES][256]u16,
    actions: [dfa_mod.MAX_STATES]?AcceptAction,

    pub const TokenIterator = struct {
        lexer: *const CompiledLexer,
        input: []const u8,
        cursor: usize = 0,
        line: usize = 1,
        col: usize = 1,

        pub fn next(self: *TokenIterator) ?Token {
            while (self.cursor < self.input.len) {
                var state: u16 = dfa_mod.START_STATE;
                var best_len: usize = 0;
                var best_action: ?AcceptAction = null;

                for (self.input[self.cursor..], 0..) |b, offset| {
                    state = self.lexer.table[state][b];
                    if (state == dfa_mod.DEAD_STATE) break;
                    if (self.lexer.actions[state]) |act| {
                        best_len = offset + 1;
                        best_action = act;
                    }
                }

                if (best_len > 0) {
                    const start = self.cursor;
                    const end = self.cursor + best_len;
                    const tok_line = self.line;
                    const tok_col = self.col;
                    advancePosition(self.input[start..end], &self.line, &self.col);
                    self.cursor = end;

                    const act = best_action.?;
                    if (act.skip) continue;

                    return Token{
                        .token_type = act.token_type,
                        .start = start,
                        .end = end,
                        .line = tok_line,
                        .column = tok_col,
                    };
                }

                // Unknown byte fallback
                const start = self.cursor;
                const tok_line = self.line;
                const tok_col = self.col;
                advancePosition(self.input[start .. start + 1], &self.line, &self.col);
                self.cursor += 1;

                return Token{
                    .token_type = .unknown,
                    .start = start,
                    .end = start + 1,
                    .line = tok_line,
                    .column = tok_col,
                };
            }
            return null;
        }
    };

    pub fn compileChecked(specs: []const RuleSpec) LexerError!CompiledLexer {
        if (specs.len == 0) return error.EmptyRules;
        if (specs.len > compiler.MAX_ACCEPT_CLASSES) return error.TooManyRules;

        var nfa = compiler.Nfa.init();
        var rule_starts: [compiler.MAX_ACCEPT_CLASSES]u16 = undefined;

        var action_palette: [compiler.MAX_ACCEPT_CLASSES]AcceptAction = undefined;
        var palette_len: usize = 0;
        var accept_remap: [compiler.MAX_ACCEPT_CLASSES + 1]u16 = @splat(0);

        for (specs, 0..) |spec, i| {
            const parsed = try compiler.parsePatternIntoNfa(&nfa, spec.pattern, spec.options, false);
            const acc = try nfa.addAccept(@intCast(i + 1));
            nfa.states[parsed.frag.end].out1 = acc;
            rule_starts[i] = parsed.frag.start;

            const act = AcceptAction{
                .token_type = spec.token_type,
                .skip = spec.skip,
            };
            var found_idx: ?usize = null;
            for (0..palette_len) |p| {
                if (action_palette[p].token_type == act.token_type and action_palette[p].skip == act.skip) {
                    found_idx = p;
                    break;
                }
            }
            if (found_idx) |p| {
                accept_remap[i + 1] = @intCast(p + 1);
            } else {
                action_palette[palette_len] = act;
                palette_len += 1;
                accept_remap[i + 1] = @intCast(palette_len);
            }
        }

        // Build unified NFA root linking all rule fragments
        var root: u16 = rule_starts[specs.len - 1];
        if (specs.len > 1) {
            var i: usize = specs.len - 1;
            while (i > 0) {
                i -= 1;
                root = try nfa.addEpsilon(rule_starts[i], root);
            }
        }

        const compiled = try compiler.determinizeAndMinimize(
            &nfa,
            root,
            true,
            accept_remap[0 .. specs.len + 1],
        );

        if (compiled.accept_ids[dfa_mod.START_STATE] != 0) {
            return error.EmptyLexerRule;
        }

        var lexer = CompiledLexer{
            .num_states = compiled.num_states,
            .table = compiled.table,
            .actions = @splat(null),
        };
        for (0..compiled.num_states) |s| {
            const aid = compiled.accept_ids[s];
            if (aid != 0) {
                lexer.actions[s] = action_palette[aid - 1];
            }
        }
        return lexer;
    }

    pub fn compile(comptime specs: []const RuleSpec) CompiledLexer {
        @setEvalBranchQuota(5_000_000);
        return compileChecked(specs) catch |err| {
            @compileError("Alexandrite comptime CompiledLexer failed: " ++ @errorName(err));
        };
    }

    pub fn iterator(self: *const CompiledLexer, input: []const u8) TokenIterator {
        return .{
            .lexer = self,
            .input = input,
        };
    }

    pub fn tokenize(self: *const CompiledLexer, input: []const u8, out_tokens: []Token) usize {
        var it = self.iterator(input);
        var count: usize = 0;
        while (count < out_tokens.len) {
            const tok = it.next() orelse break;
            out_tokens[count] = tok;
            count += 1;
        }
        return count;
    }

    pub fn countTokens(self: *const CompiledLexer, input: []const u8) usize {
        var it = self.iterator(input);
        var count: usize = 0;
        while (it.next()) |_| {
            count += 1;
        }
        return count;
    }
};

pub const default_code_rules = [_]RuleSpec{
    .{ .token_type = .whitespace, .pattern = "\\s+", .skip = true },
    .{ .token_type = .comment, .pattern = "//[^\\n]*", .skip = false },
    .{ .token_type = .string_literal, .pattern = "\"([^\"\\\\]|\\\\.)*\"", .skip = false },
    .{ .token_type = .keyword, .pattern = "fn|const|var|if|else|while|for|return|pub|struct|enum", .skip = false },
    .{ .token_type = .number, .pattern = "\\d+(\\.\\d+)?", .skip = false },
    .{ .token_type = .identifier, .pattern = "[a-zA-Z_][a-zA-Z0-9_]*", .skip = false },
    .{ .token_type = .operator, .pattern = "==|!=|<=|>=|\\+=|-=|->|[+\\-*/=<>!&|]", .skip = false },
    .{ .token_type = .punctuation, .pattern = "[(){}\\[\\],;:.]", .skip = false },
};

pub const default_code_lexer = CompiledLexer.compile(&default_code_rules);

// ============================================================================
// Unit Tests
// ============================================================================

test "Lexer Tokenization" {
    var lexer = Lexer.init();
    lexer.addRule(.number, "\\d+");
    lexer.addRule(.identifier, "[a-z]+");
    lexer.addRule(.operator, "\\+|-|\\*|/");

    const source = "val 42 + count 99";
    var tokens: [16]Token = undefined;
    const count = lexer.tokenize(source, &tokens);

    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expectEqual(TokenType.identifier, tokens[0].token_type);
    try std.testing.expectEqualStrings("val", tokens[0].lexeme(source));

    try std.testing.expectEqual(TokenType.number, tokens[1].token_type);
    try std.testing.expectEqualStrings("42", tokens[1].lexeme(source));

    try std.testing.expectEqual(TokenType.operator, tokens[2].token_type);
    try std.testing.expectEqualStrings("+", tokens[2].lexeme(source));
}

test "Lexer Explicit Whitespace Rule and Multiline Line/Column Tracking" {
    var lexer = Lexer.init();
    try lexer.addRuleChecked(.string_literal, "\"[^\"]*\"");
    try lexer.addRuleChecked(.identifier, "[a-z]+");
    try lexer.addRuleChecked(.whitespace, "[ \\t\\n]+");

    const source = "hi \"a\nb\" end";
    var tokens: [16]Token = undefined;
    const count = lexer.tokenize(source, &tokens);

    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expectEqual(TokenType.identifier, tokens[0].token_type);
    try std.testing.expectEqual(@as(usize, 1), tokens[0].line);
    try std.testing.expectEqual(@as(usize, 1), tokens[0].column);

    try std.testing.expectEqual(TokenType.whitespace, tokens[1].token_type);
    try std.testing.expectEqual(TokenType.string_literal, tokens[2].token_type);
    try std.testing.expectEqual(@as(usize, 1), tokens[2].line);
    try std.testing.expectEqual(@as(usize, 4), tokens[2].column);

    // After multiline string "a\nb", line must be 2 and col must be 4 (b + " + space -> end at col 4)
    try std.testing.expectEqual(TokenType.whitespace, tokens[3].token_type);
    try std.testing.expectEqual(@as(usize, 2), tokens[3].line);
    try std.testing.expectEqual(@as(usize, 3), tokens[3].column);

    try std.testing.expectEqual(TokenType.identifier, tokens[4].token_type);
    try std.testing.expectEqualStrings("end", tokens[4].lexeme(source));
    try std.testing.expectEqual(@as(usize, 2), tokens[4].line);
    try std.testing.expectEqual(@as(usize, 4), tokens[4].column);
}

test "Comptime CompiledLexer Single-Pass Maximal Munch and Priority" {
    const source =
        \\// header comment
        \\pub fn add(x, constant) -> 3.14 {
        \\    const msg = "hi \"zig\"";
        \\    if x >= 10 return msg;
        \\}
    ;

    var tokens: [64]Token = undefined;
    const count = default_code_lexer.tokenize(source, &tokens);
    try std.testing.expect(count >= 18);
    try std.testing.expect(default_code_lexer.num_states < dfa_mod.MAX_STATES);

    // Token 0: line comment on line 1, col 1
    try std.testing.expectEqual(TokenType.comment, tokens[0].token_type);
    try std.testing.expectEqualStrings("// header comment", tokens[0].lexeme(source));
    try std.testing.expectEqual(@as(usize, 1), tokens[0].line);
    try std.testing.expectEqual(@as(usize, 1), tokens[0].column);

    // Token 1: keyword 'pub' on line 2, col 1
    try std.testing.expectEqual(TokenType.keyword, tokens[1].token_type);
    try std.testing.expectEqualStrings("pub", tokens[1].lexeme(source));
    try std.testing.expectEqual(@as(usize, 2), tokens[1].line);
    try std.testing.expectEqual(@as(usize, 1), tokens[1].column);

    // Token 2: keyword 'fn'
    try std.testing.expectEqual(TokenType.keyword, tokens[2].token_type);
    try std.testing.expectEqualStrings("fn", tokens[2].lexeme(source));

    // Token 3: identifier 'add'
    try std.testing.expectEqual(TokenType.identifier, tokens[3].token_type);
    try std.testing.expectEqualStrings("add", tokens[3].lexeme(source));

    // Maximal munch: 'constant' must be identifier (longer than keyword 'const')
    try std.testing.expectEqual(TokenType.identifier, tokens[7].token_type);
    try std.testing.expectEqualStrings("constant", tokens[7].lexeme(source));

    // Multi-char operator '->' and float '3.14'
    try std.testing.expectEqual(TokenType.operator, tokens[9].token_type);
    try std.testing.expectEqualStrings("->", tokens[9].lexeme(source));
    try std.testing.expectEqual(TokenType.number, tokens[10].token_type);
    try std.testing.expectEqualStrings("3.14", tokens[10].lexeme(source));

    // Escaped string literal
    try std.testing.expectEqual(TokenType.keyword, tokens[12].token_type);
    try std.testing.expectEqualStrings("const", tokens[12].lexeme(source));
    try std.testing.expectEqual(TokenType.string_literal, tokens[15].token_type);
    try std.testing.expectEqualStrings("\"hi \\\"zig\\\"\"", tokens[15].lexeme(source));

    // Verify countTokens matches streaming iterator
    try std.testing.expectEqual(count, default_code_lexer.countTokens(source));
}

test "CompiledLexer Rejects Invalid and Empty-Matching Rules" {
    try std.testing.expectError(error.EmptyRules, CompiledLexer.compileChecked(&.{}));
    try std.testing.expectError(
        error.EmptyLexerRule,
        CompiledLexer.compileChecked(&.{
            .{ .token_type = .identifier, .pattern = "[a-z]*" },
        }),
    );
    try std.testing.expectError(
        error.UnsupportedAnchor,
        CompiledLexer.compileChecked(&.{
            .{ .token_type = .identifier, .pattern = "^foo" },
        }),
    );
}
