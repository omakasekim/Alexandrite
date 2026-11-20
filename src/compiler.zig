const std = @import("std");

pub const MAX_STATES: usize = 128;
pub const DEAD_STATE: u16 = 0;
pub const START_STATE: u16 = 1;

pub const MAX_NFA_STATES: usize = 512;
pub const MAX_WORK_STATES: usize = 256;
pub const MAX_REPEAT_BOUND: usize = 64;
pub const MAX_NESTING_DEPTH: usize = 32;
pub const MAX_ACCEPT_CLASSES: usize = 32;

pub const NFA_NONE: u16 = 0xFFFF;

pub const CompileError = error{
    UnclosedGroup,
    UnmatchedClosingParen,
    UnclosedCharClass,
    InvalidCharRange,
    TrailingBackslash,
    InvalidHexEscape,
    InvalidQuantifier,
    InvalidRepetitionBounds,
    RepetitionBoundTooLarge,
    NestingTooDeep,
    UnsupportedAnchor,
    InvalidInlineFlag,
    NfaStateLimitExceeded,
    DfaStateLimitExceeded,
};

pub const CompileOptions = struct {
    case_insensitive: bool = false,
    dot_matches_newline: bool = false,
    minimize: bool = true,
};

pub const ByteSet = struct {
    bits: [4]u64 = .{ 0, 0, 0, 0 },

    pub inline fn set(self: *ByteSet, b: u8) void {
        self.bits[b >> 6] |= (@as(u64, 1) << @as(u6, @truncate(b)));
    }

    pub inline fn clear(self: *ByteSet, b: u8) void {
        self.bits[b >> 6] &= ~(@as(u64, 1) << @as(u6, @truncate(b)));
    }

    pub inline fn contains(self: *const ByteSet, b: u8) bool {
        return (self.bits[b >> 6] & (@as(u64, 1) << @as(u6, @truncate(b)))) != 0;
    }

    pub fn setRange(self: *ByteSet, lo: u8, hi: u8) void {
        var b: usize = lo;
        while (b <= hi) : (b += 1) {
            self.set(@intCast(b));
        }
    }

    pub fn merge(self: *ByteSet, other: ByteSet) void {
        inline for (0..4) |i| {
            self.bits[i] |= other.bits[i];
        }
    }

    pub fn invert(self: *ByteSet) void {
        inline for (0..4) |i| {
            self.bits[i] = ~self.bits[i];
        }
    }

    pub fn applyCaseInsensitive(self: *ByteSet) void {
        var c: u8 = 'a';
        while (c <= 'z') : (c += 1) {
            const upper = c - 32;
            if (self.contains(c) or self.contains(upper)) {
                self.set(c);
                self.set(upper);
            }
        }
    }

    pub fn isEmpty(self: *const ByteSet) bool {
        return (self.bits[0] | self.bits[1] | self.bits[2] | self.bits[3]) == 0;
    }

    pub fn digits() ByteSet {
        var bs = ByteSet{};
        bs.setRange('0', '9');
        return bs;
    }

    pub fn word() ByteSet {
        var bs = ByteSet{};
        bs.setRange('a', 'z');
        bs.setRange('A', 'Z');
        bs.setRange('0', '9');
        bs.set('_');
        return bs;
    }

    pub fn whitespace() ByteSet {
        var bs = ByteSet{};
        bs.set(' ');
        bs.set('\t');
        bs.set('\r');
        bs.set('\n');
        bs.set(0x0c); // \f
        bs.set(0x0b); // \v
        return bs;
    }

    pub fn any(dot_matches_newline: bool) ByteSet {
        var bs = ByteSet{ .bits = .{ ~@as(u64, 0), ~@as(u64, 0), ~@as(u64, 0), ~@as(u64, 0) } };
        if (!dot_matches_newline) {
            bs.clear('\n');
        }
        return bs;
    }
};

pub const NfaStateKind = enum(u8) {
    epsilon,
    bytes,
    accept,
};

pub const NfaState = struct {
    kind: NfaStateKind = .epsilon,
    out1: u16 = NFA_NONE,
    out2: u16 = NFA_NONE,
    accept_id: u16 = 0,
    bytes: ByteSet = .{},
};

pub const Frag = struct {
    start: u16,
    end: u16,
};

pub const Nfa = struct {
    states: [MAX_NFA_STATES]NfaState = undefined,
    len: usize = 0,

    pub fn init() Nfa {
        return .{
            .states = undefined,
            .len = 0,
        };
    }

    pub fn addEpsilon(self: *Nfa, out1: u16, out2: u16) CompileError!u16 {
        if (self.len >= MAX_NFA_STATES) return error.NfaStateLimitExceeded;
        const idx: u16 = @intCast(self.len);
        self.states[self.len] = .{
            .kind = .epsilon,
            .out1 = out1,
            .out2 = out2,
        };
        self.len += 1;
        return idx;
    }

    pub fn addBytes(self: *Nfa, bytes: ByteSet, out1: u16) CompileError!u16 {
        if (self.len >= MAX_NFA_STATES) return error.NfaStateLimitExceeded;
        const idx: u16 = @intCast(self.len);
        self.states[self.len] = .{
            .kind = .bytes,
            .out1 = out1,
            .bytes = bytes,
        };
        self.len += 1;
        return idx;
    }

    pub fn addAccept(self: *Nfa, accept_id: u16) CompileError!u16 {
        if (self.len >= MAX_NFA_STATES) return error.NfaStateLimitExceeded;
        const idx: u16 = @intCast(self.len);
        self.states[self.len] = .{
            .kind = .accept,
            .accept_id = accept_id,
        };
        self.len += 1;
        return idx;
    }

    pub fn makeEmpty(self: *Nfa) CompileError!Frag {
        const s = try self.addEpsilon(NFA_NONE, NFA_NONE);
        return .{ .start = s, .end = s };
    }

    pub fn makeBytes(self: *Nfa, bytes: ByteSet) CompileError!Frag {
        const end = try self.addEpsilon(NFA_NONE, NFA_NONE);
        const start = try self.addBytes(bytes, end);
        return .{ .start = start, .end = end };
    }

    pub fn makeConcat(self: *Nfa, first: Frag, second: Frag) Frag {
        self.states[first.end].out1 = second.start;
        return .{ .start = first.start, .end = second.end };
    }

    pub fn makeAlt(self: *Nfa, left: Frag, right: Frag) CompileError!Frag {
        const start = try self.addEpsilon(left.start, right.start);
        const end = try self.addEpsilon(NFA_NONE, NFA_NONE);
        self.states[left.end].out1 = end;
        self.states[right.end].out1 = end;
        return .{ .start = start, .end = end };
    }

    pub fn makeStar(self: *Nfa, inner: Frag) CompileError!Frag {
        const end = try self.addEpsilon(NFA_NONE, NFA_NONE);
        const start = try self.addEpsilon(inner.start, end);
        self.states[inner.end].out1 = start;
        return .{ .start = start, .end = end };
    }

    pub fn makePlus(self: *Nfa, inner: Frag) CompileError!Frag {
        const end = try self.addEpsilon(NFA_NONE, NFA_NONE);
        self.states[inner.end].out1 = inner.start;
        self.states[inner.end].out2 = end;
        return .{ .start = inner.start, .end = end };
    }

    pub fn makeOptional(self: *Nfa, inner: Frag) CompileError!Frag {
        const end = try self.addEpsilon(NFA_NONE, NFA_NONE);
        const start = try self.addEpsilon(inner.start, end);
        self.states[inner.end].out1 = end;
        return .{ .start = start, .end = end };
    }

    pub fn cloneRange(self: *Nfa, range_start: usize, range_end: usize, orig: Frag) CompileError!Frag {
        const count = range_end - range_start;
        if (self.len + count > MAX_NFA_STATES) return error.NfaStateLimitExceeded;
        const base = self.len;
        const delta = base - range_start;

        for (0..count) |i| {
            var st = self.states[range_start + i];
            if (st.out1 != NFA_NONE) {
                st.out1 = @intCast(@as(usize, st.out1) + delta);
            }
            if (st.out2 != NFA_NONE) {
                st.out2 = @intCast(@as(usize, st.out2) + delta);
            }
            self.states[base + i] = st;
        }
        self.len += count;

        return .{
            .start = @intCast(@as(usize, orig.start) + delta),
            .end = @intCast(@as(usize, orig.end) + delta),
        };
    }
};

pub const ParsedPattern = struct {
    frag: Frag,
    anchored_start: bool,
    anchored_end: bool,
};

const AtomResult = struct {
    frag: Frag,
    quantifiable: bool,
    is_flag_only: bool = false,
};

const ClassAtom = union(enum) {
    single: u8,
    set: ByteSet,
};

const Parser = struct {
    nfa: *Nfa,
    pattern: []const u8,
    pos: usize = 0,
    depth: usize = 0,
    case_insensitive: bool,
    dot_matches_newline: bool,
    allow_anchors: bool,
    anchored_start: bool = false,
    anchored_end: bool = false,
    saw_top_level_alt: bool = false,

    fn parseTopLevel(self: *Parser) CompileError!ParsedPattern {
        const frag = try self.parseAlternation();
        if (self.pos < self.pattern.len) {
            if (self.pattern[self.pos] == ')') {
                return error.UnmatchedClosingParen;
            }
            return error.InvalidQuantifier;
        }
        return .{
            .frag = frag,
            .anchored_start = self.anchored_start,
            .anchored_end = self.anchored_end,
        };
    }

    fn parseAlternation(self: *Parser) CompileError!Frag {
        const saved_ci = self.case_insensitive;
        const saved_dot = self.dot_matches_newline;
        defer {
            self.case_insensitive = saved_ci;
            self.dot_matches_newline = saved_dot;
        }

        var left = try self.parseConcat();
        while (self.pos < self.pattern.len and self.pattern[self.pos] == '|') {
            if (self.depth == 0) {
                if (self.anchored_start or self.anchored_end) {
                    return error.UnsupportedAnchor;
                }
                self.saw_top_level_alt = true;
            }
            self.pos += 1;
            const right = try self.parseConcat();
            left = try self.nfa.makeAlt(left, right);
        }
        return left;
    }

    fn parseConcat(self: *Parser) CompileError!Frag {
        var result: ?Frag = null;
        var at_expr_start = (self.depth == 0 and !self.saw_top_level_alt and !self.anchored_start);

        while (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];
            if (c == '|' or c == ')') break;

            if (c == '^') {
                if (!self.allow_anchors or !at_expr_start) {
                    return error.UnsupportedAnchor;
                }
                self.anchored_start = true;
                self.pos += 1;
                at_expr_start = false;
                if (self.pos < self.pattern.len and isQuantifierStart(self.pattern[self.pos])) {
                    return error.InvalidQuantifier;
                }
                continue;
            }

            if (c == '$') {
                if (!self.allow_anchors or self.depth != 0 or self.saw_top_level_alt or self.pos + 1 != self.pattern.len) {
                    return error.UnsupportedAnchor;
                }
                self.anchored_end = true;
                self.pos += 1;
                at_expr_start = false;
                continue;
            }

            if (isQuantifierStart(c)) {
                return error.InvalidQuantifier;
            }

            const snap_len = self.nfa.len;
            const atom = try self.parseAtom();
            const atom_end_len = self.nfa.len;

            if (!atom.is_flag_only) {
                at_expr_start = false;
            }

            var piece = atom.frag;
            if (self.pos < self.pattern.len and isQuantifierStart(self.pattern[self.pos])) {
                if (!atom.quantifiable) {
                    return error.InvalidQuantifier;
                }
                piece = try self.parseQuantifier(snap_len, atom_end_len, piece);
                if (self.pos < self.pattern.len and isQuantifierStart(self.pattern[self.pos])) {
                    return error.InvalidQuantifier;
                }
            }

            if (result) |prev| {
                result = self.nfa.makeConcat(prev, piece);
            } else {
                result = piece;
            }
        }

        return result orelse try self.nfa.makeEmpty();
    }

    fn isQuantifierStart(c: u8) bool {
        return c == '*' or c == '+' or c == '?' or c == '{';
    }

    fn parseQuantifier(self: *Parser, snap_len: usize, atom_end_len: usize, atom_frag: Frag) CompileError!Frag {
        const q = self.pattern[self.pos];
        if (q == '*') {
            self.pos += 1;
            return try self.nfa.makeStar(atom_frag);
        }
        if (q == '+') {
            self.pos += 1;
            return try self.nfa.makePlus(atom_frag);
        }
        if (q == '?') {
            self.pos += 1;
            return try self.nfa.makeOptional(atom_frag);
        }

        // Bounded repetition: {m}, {m,}, {m,n}
        self.pos += 1; // skip '{'
        const min_val = try self.parseRepeatNumber();
        var max_val: ?usize = min_val;

        if (self.pos < self.pattern.len and self.pattern[self.pos] == ',') {
            self.pos += 1;
            if (self.pos < self.pattern.len and self.pattern[self.pos] == '}') {
                max_val = null; // {m,}
            } else {
                max_val = try self.parseRepeatNumber();
            }
        }

        if (self.pos >= self.pattern.len or self.pattern[self.pos] != '}') {
            return error.InvalidRepetitionBounds;
        }
        self.pos += 1; // skip '}'

        if (min_val > MAX_REPEAT_BOUND) return error.RepetitionBoundTooLarge;
        if (max_val) |mx| {
            if (mx > MAX_REPEAT_BOUND) return error.RepetitionBoundTooLarge;
            if (mx < min_val) return error.InvalidRepetitionBounds;
        }

        // Apply repetition without mutating original range before cloning
        if (max_val) |mx| {
            if (mx == 0) {
                self.nfa.len = snap_len;
                return try self.nfa.makeEmpty();
            }
            if (min_val == 0 and mx == 1) {
                return try self.nfa.makeOptional(atom_frag);
            }
            if (min_val == 1 and mx == 1) {
                return atom_frag;
            }

            var copies: [MAX_REPEAT_BOUND]Frag = undefined;
            copies[0] = atom_frag;
            for (1..mx) |k| {
                copies[k] = try self.nfa.cloneRange(snap_len, atom_end_len, atom_frag);
            }

            // Wrap optional tail copies in makeOptional
            for (min_val..mx) |k| {
                copies[k] = try self.nfa.makeOptional(copies[k]);
            }

            var chain = copies[0];
            for (1..mx) |k| {
                chain = self.nfa.makeConcat(chain, copies[k]);
            }
            return chain;
        } else {
            // Unbounded upper limit: {min,}
            if (min_val == 0) {
                return try self.nfa.makeStar(atom_frag);
            }
            if (min_val == 1) {
                return try self.nfa.makePlus(atom_frag);
            }

            var copies: [MAX_REPEAT_BOUND]Frag = undefined;
            copies[0] = atom_frag;
            for (1..min_val) |k| {
                copies[k] = try self.nfa.cloneRange(snap_len, atom_end_len, atom_frag);
            }
            copies[min_val - 1] = try self.nfa.makePlus(copies[min_val - 1]);

            var chain = copies[0];
            for (1..min_val) |k| {
                chain = self.nfa.makeConcat(chain, copies[k]);
            }
            return chain;
        }
    }

    fn parseRepeatNumber(self: *Parser) CompileError!usize {
        if (self.pos >= self.pattern.len) return error.InvalidRepetitionBounds;
        const first = self.pattern[self.pos];
        if (first < '0' or first > '9') return error.InvalidRepetitionBounds;

        var value: usize = 0;
        while (self.pos < self.pattern.len) {
            const ch = self.pattern[self.pos];
            if (ch < '0' or ch > '9') break;
            const digit: usize = ch - '0';
            if (value > MAX_REPEAT_BOUND) {
                // Keep scanning digits to validate syntax, then report too large
                self.pos += 1;
                continue;
            }
            value = value * 10 + digit;
            self.pos += 1;
        }
        return value;
    }

    fn parseAtom(self: *Parser) CompileError!AtomResult {
        const c = self.pattern[self.pos];

        if (c == '(') {
            if (self.depth >= MAX_NESTING_DEPTH) return error.NestingTooDeep;
            self.pos += 1;

            if (self.pos < self.pattern.len and self.pattern[self.pos] == '?') {
                self.pos += 1;
                if (self.pos >= self.pattern.len) return error.UnclosedGroup;

                if (self.pattern[self.pos] == ':') {
                    self.pos += 1;
                    self.depth += 1;
                    const inner = try self.parseAlternation();
                    self.depth -= 1;
                    if (self.pos >= self.pattern.len or self.pattern[self.pos] != ')') {
                        return error.UnclosedGroup;
                    }
                    self.pos += 1;
                    return .{ .frag = inner, .quantifiable = true };
                }

                // Inline flags: (?i), (?s), (?is), (?-i), (?i:...)
                const saved_ci = self.case_insensitive;
                const saved_dot = self.dot_matches_newline;
                var new_ci = saved_ci;
                var new_dot = saved_dot;
                var negating = false;
                var saw_flag = false;

                while (self.pos < self.pattern.len) {
                    const fc = self.pattern[self.pos];
                    if (fc == '-') {
                        if (negating) return error.InvalidInlineFlag;
                        negating = true;
                        self.pos += 1;
                    } else if (fc == 'i') {
                        new_ci = !negating;
                        saw_flag = true;
                        self.pos += 1;
                    } else if (fc == 's') {
                        new_dot = !negating;
                        saw_flag = true;
                        self.pos += 1;
                    } else {
                        break;
                    }
                }

                if (!saw_flag or self.pos >= self.pattern.len) {
                    return error.InvalidInlineFlag;
                }

                if (self.pattern[self.pos] == ')') {
                    self.pos += 1;
                    self.case_insensitive = new_ci;
                    self.dot_matches_newline = new_dot;
                    return .{
                        .frag = try self.nfa.makeEmpty(),
                        .quantifiable = false,
                        .is_flag_only = true,
                    };
                }

                if (self.pattern[self.pos] == ':') {
                    self.pos += 1;
                    self.case_insensitive = new_ci;
                    self.dot_matches_newline = new_dot;
                    self.depth += 1;
                    const inner = self.parseAlternation() catch |err| {
                        self.depth -= 1;
                        self.case_insensitive = saved_ci;
                        self.dot_matches_newline = saved_dot;
                        return err;
                    };
                    self.depth -= 1;
                    self.case_insensitive = saved_ci;
                    self.dot_matches_newline = saved_dot;
                    if (self.pos >= self.pattern.len or self.pattern[self.pos] != ')') {
                        return error.UnclosedGroup;
                    }
                    self.pos += 1;
                    return .{ .frag = inner, .quantifiable = true };
                }

                return error.InvalidInlineFlag;
            }

            self.depth += 1;
            const inner = try self.parseAlternation();
            self.depth -= 1;
            if (self.pos >= self.pattern.len or self.pattern[self.pos] != ')') {
                return error.UnclosedGroup;
            }
            self.pos += 1;
            return .{ .frag = inner, .quantifiable = true };
        }

        if (c == '[') {
            const bs = try self.parseCharClass();
            return .{ .frag = try self.nfa.makeBytes(bs), .quantifiable = true };
        }

        if (c == '.') {
            self.pos += 1;
            return .{
                .frag = try self.nfa.makeBytes(ByteSet.any(self.dot_matches_newline)),
                .quantifiable = true,
            };
        }

        if (c == '\\') {
            const esc = try self.parseEscape();
            var bs = switch (esc) {
                .single => |b| blk: {
                    var s = ByteSet{};
                    s.set(b);
                    break :blk s;
                },
                .set => |s| s,
            };
            if (self.case_insensitive) {
                bs.applyCaseInsensitive();
            }
            return .{ .frag = try self.nfa.makeBytes(bs), .quantifiable = true };
        }

        self.pos += 1;
        var bs = ByteSet{};
        bs.set(c);
        if (self.case_insensitive) {
            bs.applyCaseInsensitive();
        }
        return .{ .frag = try self.nfa.makeBytes(bs), .quantifiable = true };
    }

    fn parseEscape(self: *Parser) CompileError!ClassAtom {
        // Assumes self.pattern[self.pos] == '\\'
        self.pos += 1;
        if (self.pos >= self.pattern.len) return error.TrailingBackslash;
        const ch = self.pattern[self.pos];
        self.pos += 1;

        return switch (ch) {
            'd' => .{ .set = ByteSet.digits() },
            'D' => blk: {
                var s = ByteSet.digits();
                s.invert();
                break :blk .{ .set = s };
            },
            'w' => .{ .set = ByteSet.word() },
            'W' => blk: {
                var s = ByteSet.word();
                s.invert();
                break :blk .{ .set = s };
            },
            's' => .{ .set = ByteSet.whitespace() },
            'S' => blk: {
                var s = ByteSet.whitespace();
                s.invert();
                break :blk .{ .set = s };
            },
            'n' => .{ .single = '\n' },
            'r' => .{ .single = '\r' },
            't' => .{ .single = '\t' },
            'f' => .{ .single = 0x0c },
            'v' => .{ .single = 0x0b },
            '0' => .{ .single = 0x00 },
            'x' => .{ .single = try self.parseHexByte() },
            else => .{ .single = ch },
        };
    }

    fn parseHexByte(self: *Parser) CompileError!u8 {
        if (self.pos + 2 > self.pattern.len) return error.InvalidHexEscape;
        const hi = hexDigit(self.pattern[self.pos]) orelse return error.InvalidHexEscape;
        const lo = hexDigit(self.pattern[self.pos + 1]) orelse return error.InvalidHexEscape;
        self.pos += 2;
        return (hi << 4) | lo;
    }

    fn hexDigit(c: u8) ?u8 {
        if (c >= '0' and c <= '9') return c - '0';
        if (c >= 'a' and c <= 'f') return c - 'a' + 10;
        if (c >= 'A' and c <= 'F') return c - 'A' + 10;
        return null;
    }

    fn parseCharClass(self: *Parser) CompileError!ByteSet {
        // Assumes self.pattern[self.pos] == '['
        self.pos += 1;
        if (self.pos >= self.pattern.len) return error.UnclosedCharClass;

        var negated = false;
        if (self.pattern[self.pos] == '^') {
            negated = true;
            self.pos += 1;
        }
        if (self.pos >= self.pattern.len) return error.UnclosedCharClass;

        var bs = ByteSet{};
        var first_item = true;

        while (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];
            if (c == ']' and !first_item) {
                self.pos += 1;
                if (self.case_insensitive) {
                    bs.applyCaseInsensitive();
                }
                if (negated) {
                    bs.invert();
                }
                return bs;
            }
            first_item = false;

            const left = try self.parseClassAtom();

            // Check for range a-z (only when '-' is NOT immediately followed by ']')
            if (self.pos + 1 < self.pattern.len and self.pattern[self.pos] == '-' and self.pattern[self.pos + 1] != ']') {
                self.pos += 1; // skip '-'
                const right = try self.parseClassAtom();
                const lo = switch (left) {
                    .single => |b| b,
                    .set => return error.InvalidCharRange,
                };
                const hi = switch (right) {
                    .single => |b| b,
                    .set => return error.InvalidCharRange,
                };
                if (lo > hi) return error.InvalidCharRange;
                bs.setRange(lo, hi);
            } else {
                switch (left) {
                    .single => |b| bs.set(b),
                    .set => |s| bs.merge(s),
                }
            }
        }

        return error.UnclosedCharClass;
    }

    fn parseClassAtom(self: *Parser) CompileError!ClassAtom {
        const c = self.pattern[self.pos];
        if (c == '\\') {
            return try self.parseEscape();
        }
        self.pos += 1;
        return .{ .single = c };
    }
};

pub fn parsePatternIntoNfa(
    nfa: *Nfa,
    pattern: []const u8,
    options: CompileOptions,
    allow_anchors: bool,
) CompileError!ParsedPattern {
    var parser = Parser{
        .nfa = nfa,
        .pattern = pattern,
        .case_insensitive = options.case_insensitive,
        .dot_matches_newline = options.dot_matches_newline,
        .allow_anchors = allow_anchors,
    };
    return try parser.parseTopLevel();
}

const EquivClasses = struct {
    byte_to_class: [256]u8,
    class_rep: [256]u8,
    num_classes: usize,
};

fn computeEquivClasses(nfa: *const Nfa) EquivClasses {
    var byte_to_class: [256]u8 = @splat(0);
    var num_classes: usize = 1;

    for (0..nfa.len) |s| {
        if (num_classes == 256) break;
        if (nfa.states[s].kind != .bytes) continue;
        const mask = nfa.states[s].bytes;
        if (mask.isEmpty()) continue;

        var total_count: [256]u16 = @splat(0);
        var in_count: [256]u16 = @splat(0);

        for (0..256) |b| {
            const cls = byte_to_class[b];
            total_count[cls] += 1;
            if (mask.contains(@intCast(b))) {
                in_count[cls] += 1;
            }
        }

        var split_target: [256]u8 = @splat(0);
        var did_split: [256]bool = @splat(false);
        var any_split = false;

        const old_num = num_classes;
        for (0..old_num) |cls| {
            if (in_count[cls] > 0 and in_count[cls] < total_count[cls]) {
                did_split[cls] = true;
                split_target[cls] = @intCast(num_classes);
                num_classes += 1;
                any_split = true;
            }
        }

        if (any_split) {
            for (0..256) |b| {
                const cls = byte_to_class[b];
                if (did_split[cls] and mask.contains(@intCast(b))) {
                    byte_to_class[b] = split_target[cls];
                }
            }
        }
    }

    var class_rep: [256]u8 = @splat(0);
    var seen: [256]bool = @splat(false);
    for (0..256) |b| {
        const cls = byte_to_class[b];
        if (!seen[cls]) {
            seen[cls] = true;
            class_rep[cls] = @intCast(b);
        }
    }

    return .{
        .byte_to_class = byte_to_class,
        .class_rep = class_rep,
        .num_classes = num_classes,
    };
}

const NfaSetWords = MAX_NFA_STATES / 64;

const NfaSet = struct {
    words: [NfaSetWords]u64 = @splat(0),

    inline fn set(self: *NfaSet, idx: u16) void {
        self.words[idx >> 6] |= (@as(u64, 1) << @as(u6, @truncate(idx)));
    }

    inline fn contains(self: *const NfaSet, idx: u16) bool {
        return (self.words[idx >> 6] & (@as(u64, 1) << @as(u6, @truncate(idx)))) != 0;
    }

    fn isEmpty(self: *const NfaSet) bool {
        var acc: u64 = 0;
        inline for (0..NfaSetWords) |i| {
            acc |= self.words[i];
        }
        return acc == 0;
    }

    fn eql(a: *const NfaSet, b: *const NfaSet) bool {
        inline for (0..NfaSetWords) |i| {
            if (a.words[i] != b.words[i]) return false;
        }
        return true;
    }
};

fn epsilonClosure(nfa: *const Nfa, set: *NfaSet) void {
    var stack: [MAX_NFA_STATES]u16 = undefined;
    var sp: usize = 0;

    for (0..NfaSetWords) |w| {
        var bits = set.words[w];
        while (bits != 0) {
            const tz: u6 = @intCast(@ctz(bits));
            const idx: u16 = @intCast((w << 6) | @as(usize, tz));
            stack[sp] = idx;
            sp += 1;
            bits &= bits - 1;
        }
    }

    while (sp > 0) {
        sp -= 1;
        const s = stack[sp];
        const st = nfa.states[s];
        if (st.kind != .epsilon) continue;

        if (st.out1 != NFA_NONE and !set.contains(st.out1)) {
            set.set(st.out1);
            stack[sp] = st.out1;
            sp += 1;
        }
        if (st.out2 != NFA_NONE and !set.contains(st.out2)) {
            set.set(st.out2);
            stack[sp] = st.out2;
            sp += 1;
        }
    }
}

fn acceptIdOf(nfa: *const Nfa, set: *const NfaSet) u16 {
    var best: u16 = 0;
    for (0..NfaSetWords) |w| {
        var bits = set.words[w];
        while (bits != 0) {
            const tz: u6 = @intCast(@ctz(bits));
            const idx: usize = (w << 6) | @as(usize, tz);
            const st = nfa.states[idx];
            if (st.kind == .accept and st.accept_id != 0) {
                if (best == 0 or st.accept_id < best) {
                    best = st.accept_id;
                }
            }
            bits &= bits - 1;
        }
    }
    return best;
}

fn moveOnByte(nfa: *const Nfa, src: *const NfaSet, byte_val: u8) NfaSet {
    var dst = NfaSet{};
    for (0..NfaSetWords) |w| {
        var bits = src.words[w];
        while (bits != 0) {
            const tz: u6 = @intCast(@ctz(bits));
            const idx: usize = (w << 6) | @as(usize, tz);
            const st = nfa.states[idx];
            if (st.kind == .bytes and st.bytes.contains(byte_val) and st.out1 != NFA_NONE) {
                dst.set(st.out1);
            }
            bits &= bits - 1;
        }
    }
    return dst;
}

pub const CompiledTable = struct {
    num_states: u16,
    table: [MAX_STATES][256]u16,
    accept_ids: [MAX_STATES]u16,
    equiv_classes: u16,
};

/// Determinizes an NFA starting at `nfa_start` via byte equivalence classes +
/// subset construction, optionally remapping accept IDs via `accept_remap`
/// before running Moore/Hopcroft partition-refinement minimization.
pub fn determinizeAndMinimize(
    nfa: *const Nfa,
    nfa_start: u16,
    minimize: bool,
    accept_remap: ?[]const u16,
) CompileError!CompiledTable {
    const eq = computeEquivClasses(nfa);

    var dfa_sets: [MAX_WORK_STATES]NfaSet = undefined;
    var work_trans: [MAX_WORK_STATES][256]u8 = undefined;
    var work_accept: [MAX_WORK_STATES]u16 = @splat(0);

    // State 0 = DEAD_STATE
    dfa_sets[DEAD_STATE] = NfaSet{};
    for (0..eq.num_classes) |c| {
        work_trans[DEAD_STATE][c] = DEAD_STATE;
    }
    work_accept[DEAD_STATE] = 0;

    // State 1 = START_STATE
    var start_set = NfaSet{};
    start_set.set(nfa_start);
    epsilonClosure(nfa, &start_set);

    dfa_sets[START_STATE] = start_set;
    work_accept[START_STATE] = remapAccept(acceptIdOf(nfa, &start_set), accept_remap);

    var work_num_states: usize = 2;
    var queue_idx: usize = START_STATE;

    while (queue_idx < work_num_states) : (queue_idx += 1) {
        const cur_set = dfa_sets[queue_idx];

        for (0..eq.num_classes) |c| {
            const rep_byte = eq.class_rep[c];
            var next_set = moveOnByte(nfa, &cur_set, rep_byte);
            if (next_set.isEmpty()) {
                work_trans[queue_idx][c] = DEAD_STATE;
                continue;
            }
            epsilonClosure(nfa, &next_set);

            // Search existing DFA states
            var found: ?usize = null;
            for (1..work_num_states) |existing| {
                if (NfaSet.eql(&dfa_sets[existing], &next_set)) {
                    found = existing;
                    break;
                }
            }

            if (found) |target| {
                work_trans[queue_idx][c] = @intCast(target);
            } else {
                if (work_num_states >= MAX_WORK_STATES) {
                    return error.DfaStateLimitExceeded;
                }
                const target = work_num_states;
                dfa_sets[target] = next_set;
                work_accept[target] = remapAccept(acceptIdOf(nfa, &next_set), accept_remap);
                work_trans[queue_idx][c] = @intCast(target);
                work_num_states += 1;
            }
        }
    }

    if (!minimize) {
        if (work_num_states > MAX_STATES) {
            return error.DfaStateLimitExceeded;
        }
        return expandTable(
            work_num_states,
            &work_trans,
            &work_accept,
            &eq,
        );
    }

    return minimizeAndExpand(
        work_num_states,
        &work_trans,
        &work_accept,
        &eq,
    );
}

fn remapAccept(id: u16, accept_remap: ?[]const u16) u16 {
    if (id == 0) return 0;
    if (accept_remap) |remap| {
        if (id < remap.len) return remap[id];
    }
    return id;
}

fn expandTable(
    num_states: usize,
    work_trans: *const [MAX_WORK_STATES][256]u8,
    work_accept: *const [MAX_WORK_STATES]u16,
    eq: *const EquivClasses,
) CompiledTable {
    var out = CompiledTable{
        .num_states = @intCast(num_states),
        .table = undefined,
        .accept_ids = @splat(0),
        .equiv_classes = @intCast(eq.num_classes),
    };

    for (0..MAX_STATES) |s| {
        for (0..256) |b| {
            out.table[s][b] = DEAD_STATE;
        }
    }

    for (0..num_states) |s| {
        out.accept_ids[s] = work_accept[s];
        for (0..256) |b| {
            const cls = eq.byte_to_class[b];
            out.table[s][b] = work_trans[s][cls];
        }
    }

    return out;
}

fn minimizeAndExpand(
    work_num_states: usize,
    work_trans: *const [MAX_WORK_STATES][256]u8,
    work_accept: *const [MAX_WORK_STATES]u16,
    eq: *const EquivClasses,
) CompileError!CompiledTable {
    // Initial partition by distinct accept_id
    var part: [MAX_WORK_STATES]u16 = @splat(0);
    var distinct_accepts: [MAX_WORK_STATES]u16 = undefined;
    var num_blocks: usize = 0;

    for (0..work_num_states) |s| {
        const aid = work_accept[s];
        var blk_opt: ?usize = null;
        for (0..num_blocks) |b| {
            if (distinct_accepts[b] == aid) {
                blk_opt = b;
                break;
            }
        }
        if (blk_opt) |b| {
            part[s] = @intCast(b);
        } else {
            distinct_accepts[num_blocks] = aid;
            part[s] = @intCast(num_blocks);
            num_blocks += 1;
        }
    }

    // Moore partition refinement until fixed point
    var new_part: [MAX_WORK_STATES]u16 = undefined;
    var block_rep: [MAX_WORK_STATES]u16 = undefined;
    var block_old_part: [MAX_WORK_STATES]u16 = undefined;

    while (true) {
        var new_num_blocks: usize = 0;

        for (0..work_num_states) |s| {
            const old_p = part[s];
            var matched_block: ?usize = null;

            for (0..new_num_blocks) |nb| {
                if (block_old_part[nb] != old_p) continue;
                const rep = block_rep[nb];
                var same = true;
                for (0..eq.num_classes) |c| {
                    if (part[work_trans[s][c]] != part[work_trans[rep][c]]) {
                        same = false;
                        break;
                    }
                }
                if (same) {
                    matched_block = nb;
                    break;
                }
            }

            if (matched_block) |nb| {
                new_part[s] = @intCast(nb);
            } else {
                block_rep[new_num_blocks] = @intCast(s);
                block_old_part[new_num_blocks] = old_p;
                new_part[s] = @intCast(new_num_blocks);
                new_num_blocks += 1;
            }
        }

        if (new_num_blocks == num_blocks) {
            break;
        }
        for (0..work_num_states) |s| {
            part[s] = new_part[s];
        }
        num_blocks = new_num_blocks;
    }

    // Build representative for each final block
    var final_rep: [MAX_WORK_STATES]u16 = @splat(0);
    var rep_set: [MAX_WORK_STATES]bool = @splat(false);
    for (0..work_num_states) |s| {
        const blk = part[s];
        if (!rep_set[blk]) {
            rep_set[blk] = true;
            final_rep[blk] = @intCast(s);
        }
    }

    var out = CompiledTable{
        .num_states = 2,
        .table = undefined,
        .accept_ids = @splat(0),
        .equiv_classes = @intCast(eq.num_classes),
    };
    for (0..MAX_STATES) |s| {
        for (0..256) |b| {
            out.table[s][b] = DEAD_STATE;
        }
    }

    const dead_block = part[DEAD_STATE];
    const start_block = part[START_STATE];

    // Empty language: START_STATE is equivalent to DEAD_STATE
    if (start_block == dead_block) {
        out.num_states = 2;
        out.equiv_classes = 1;
        return out;
    }

    // Canonical BFS renumbering: DEAD_STATE = 0, START_STATE = 1, live states = 2..
    var block_to_final: [MAX_WORK_STATES]?u16 = @splat(null);
    block_to_final[dead_block] = DEAD_STATE;
    block_to_final[start_block] = START_STATE;

    var bfs_blocks: [MAX_STATES]u16 = undefined;
    bfs_blocks[0] = start_block;
    var bfs_head: usize = 0;
    var bfs_tail: usize = 1;
    var final_num_states: usize = 2;

    while (bfs_head < bfs_tail) : (bfs_head += 1) {
        const blk = bfs_blocks[bfs_head];
        const rep = final_rep[blk];

        for (0..eq.num_classes) |c| {
            const next_blk = part[work_trans[rep][c]];
            if (block_to_final[next_blk] == null) {
                if (final_num_states >= MAX_STATES) {
                    return error.DfaStateLimitExceeded;
                }
                block_to_final[next_blk] = @intCast(final_num_states);
                bfs_blocks[bfs_tail] = next_blk;
                bfs_tail += 1;
                final_num_states += 1;
            }
        }
    }

    out.num_states = @intCast(final_num_states);

    for (0..bfs_tail) |i| {
        const blk = bfs_blocks[i];
        const fs = block_to_final[blk].?;
        const rep = final_rep[blk];
        out.accept_ids[fs] = work_accept[rep];

        for (0..256) |b| {
            const cls = eq.byte_to_class[b];
            const target_blk = part[work_trans[rep][cls]];
            out.table[fs][b] = block_to_final[target_blk] orelse DEAD_STATE;
        }
    }

    return out;
}
