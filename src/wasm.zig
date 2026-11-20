const std = @import("std");
const dfa_mod = @import("dfa.zig");
const Dfa = dfa_mod.Dfa;
const CompileError = dfa_mod.CompileError;
const CompileOptions = dfa_mod.CompileOptions;

pub const ErrorCode = enum(u32) {
    none = 0,
    buffer_overflow = 1,
    unclosed_group = 2,
    unmatched_closing_paren = 3,
    unclosed_char_class = 4,
    invalid_char_range = 5,
    trailing_backslash = 6,
    invalid_hex_escape = 7,
    invalid_quantifier = 8,
    invalid_repetition_bounds = 9,
    repetition_bound_too_large = 10,
    nesting_too_deep = 11,
    unsupported_anchor = 12,
    invalid_inline_flag = 13,
    nfa_state_limit_exceeded = 14,
    dfa_state_limit_exceeded = 15,
};

var global_dfa: Dfa = undefined;
var is_initialized: bool = false;
var last_error: ErrorCode = .none;
var last_match_end: i32 = -1;
var memory_buffer: [65536]u8 = undefined;

fn mapError(err: CompileError) ErrorCode {
    return switch (err) {
        error.UnclosedGroup => .unclosed_group,
        error.UnmatchedClosingParen => .unmatched_closing_paren,
        error.UnclosedCharClass => .unclosed_char_class,
        error.InvalidCharRange => .invalid_char_range,
        error.TrailingBackslash => .trailing_backslash,
        error.InvalidHexEscape => .invalid_hex_escape,
        error.InvalidQuantifier => .invalid_quantifier,
        error.InvalidRepetitionBounds => .invalid_repetition_bounds,
        error.RepetitionBoundTooLarge => .repetition_bound_too_large,
        error.NestingTooDeep => .nesting_too_deep,
        error.UnsupportedAnchor => .unsupported_anchor,
        error.InvalidInlineFlag => .invalid_inline_flag,
        error.NfaStateLimitExceeded => .nfa_state_limit_exceeded,
        error.DfaStateLimitExceeded => .dfa_state_limit_exceeded,
    };
}

export fn alexandrite_get_buffer() [*]u8 {
    return &memory_buffer;
}

export fn alexandrite_get_buffer_capacity() u32 {
    return memory_buffer.len;
}

export fn alexandrite_get_last_error() u32 {
    return @backingInt(last_error);
}

export fn alexandrite_compile_flags(len: usize, flags: u32) u32 {
    last_match_end = -1;
    if (len > memory_buffer.len) {
        is_initialized = false;
        last_error = .buffer_overflow;
        return 0;
    }
    const pattern = memory_buffer[0..len];
    const opts = CompileOptions{
        .case_insensitive = (flags & 0x1) != 0,
        .dot_matches_newline = (flags & 0x2) != 0,
        .minimize = (flags & 0x4) == 0,
    };
    global_dfa = Dfa.compileWithOptions(pattern, opts) catch |err| {
        is_initialized = false;
        last_error = mapError(err);
        return 0;
    };
    is_initialized = true;
    last_error = .none;
    return global_dfa.num_states;
}

export fn alexandrite_compile(len: usize) u32 {
    return alexandrite_compile_flags(len, 0);
}

export fn alexandrite_matches(len: usize) u32 {
    if (!is_initialized or len > memory_buffer.len) return 0;
    const input = memory_buffer[0..len];
    return if (global_dfa.matches(input)) 1 else 0;
}

export fn alexandrite_find_start(len: usize) i32 {
    if (!is_initialized or len > memory_buffer.len) return -1;
    const input = memory_buffer[0..len];
    if (global_dfa.find(input)) |span| {
        last_match_end = @intCast(span.end);
        return @intCast(span.start);
    }
    last_match_end = -1;
    return -1;
}

export fn alexandrite_find_end(len: usize) i32 {
    if (!is_initialized or len > memory_buffer.len) return -1;
    const input = memory_buffer[0..len];
    if (global_dfa.find(input)) |span| {
        last_match_end = @intCast(span.end);
        return @intCast(span.end);
    }
    last_match_end = -1;
    return -1;
}

export fn alexandrite_find_from(len: usize, offset: usize) i32 {
    if (!is_initialized or len > memory_buffer.len or offset > len) {
        last_match_end = -1;
        return -1;
    }
    const input = memory_buffer[0..len];
    if (global_dfa.findAt(input, offset)) |span| {
        last_match_end = @intCast(span.end);
        return @intCast(span.start);
    }
    last_match_end = -1;
    return -1;
}

export fn alexandrite_last_match_end() i32 {
    return last_match_end;
}

export fn alexandrite_scan_count(len: usize) u32 {
    if (!is_initialized or len > memory_buffer.len) return 0;
    const input = memory_buffer[0..len];
    return @intCast(global_dfa.scanCount(input));
}

export fn alexandrite_get_states() u32 {
    if (!is_initialized) return 0;
    return global_dfa.num_states;
}

export fn alexandrite_is_accepting(state: u32) u32 {
    if (!is_initialized or state >= dfa_mod.MAX_STATES) return 0;
    return if (global_dfa.accepting[state]) 1 else 0;
}

export fn alexandrite_get_transition(state: u32, byte_val: u32) u32 {
    if (!is_initialized or state >= dfa_mod.MAX_STATES or byte_val >= 256) return dfa_mod.DEAD_STATE;
    return global_dfa.table[state][byte_val];
}

export fn alexandrite_get_equiv_classes() u32 {
    if (!is_initialized) return 0;
    return @intCast(global_dfa.equivClassCount());
}

export fn alexandrite_is_empty_language() u32 {
    if (!is_initialized) return 1;
    return if (global_dfa.isEmptyLanguage()) 1 else 0;
}

export fn alexandrite_is_finite_language() u32 {
    if (!is_initialized) return 1;
    return if (global_dfa.isFiniteLanguage()) 1 else 0;
}

test "WASM Export Interface Compatibility and Extended Introspection" {
    const buf = alexandrite_get_buffer();
    try std.testing.expectEqual(@as(u32, 65536), alexandrite_get_buffer_capacity());

    // Compile valid regex
    const pat = "\\d{3}-\\d{2}-\\d{4}";
    @memcpy(buf[0..pat.len], pat);
    const states = alexandrite_compile(pat.len);
    try std.testing.expect(states >= 12);
    try std.testing.expectEqual(@as(u32, 0), alexandrite_get_last_error());
    try std.testing.expectEqual(states, alexandrite_get_states());
    try std.testing.expectEqual(@as(u32, 0), alexandrite_is_empty_language());
    try std.testing.expectEqual(@as(u32, 1), alexandrite_is_finite_language());
    try std.testing.expectEqual(@as(u32, 3), alexandrite_get_equiv_classes());

    // Full match
    const ssn = "123-45-6789";
    @memcpy(buf[0..ssn.len], ssn);
    try std.testing.expectEqual(@as(u32, 1), alexandrite_matches(ssn.len));

    // Multi-match find_from + scan_count
    const log = "a=111-22-3333 b=444-55-6666";
    @memcpy(buf[0..log.len], log);
    try std.testing.expectEqual(@as(u32, 2), alexandrite_scan_count(log.len));
    try std.testing.expectEqual(@as(i32, 2), alexandrite_find_start(log.len));
    try std.testing.expectEqual(@as(i32, 13), alexandrite_find_end(log.len));

    const second_start = alexandrite_find_from(log.len, 13);
    try std.testing.expectEqual(@as(i32, 16), second_start);
    try std.testing.expectEqual(@as(i32, 27), alexandrite_last_match_end());
    try std.testing.expectEqual(@as(i32, -1), alexandrite_find_from(log.len, 27));

    // Case-insensitive flag compilation
    const ci_pat = "get|post";
    @memcpy(buf[0..ci_pat.len], ci_pat);
    try std.testing.expect(alexandrite_compile_flags(ci_pat.len, 0x1) >= 2);
    const upper = "POST";
    @memcpy(buf[0..upper.len], upper);
    try std.testing.expectEqual(@as(u32, 1), alexandrite_matches(upper.len));

    // Error handling: invalid regex returns 0 states and sets specific error code
    const bad = "[z-a]";
    @memcpy(buf[0..bad.len], bad);
    try std.testing.expectEqual(@as(u32, 0), alexandrite_compile(bad.len));
    try std.testing.expectEqual(@backingInt(ErrorCode.invalid_char_range), alexandrite_get_last_error());
    try std.testing.expectEqual(@as(u32, 0), alexandrite_get_states());
}
