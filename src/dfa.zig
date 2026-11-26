const std = @import("std");
pub const compiler = @import("compiler.zig");

pub const MAX_STATES: usize = compiler.MAX_STATES;
pub const DEAD_STATE: u16 = compiler.DEAD_STATE;
pub const START_STATE: u16 = compiler.START_STATE;

pub const CompileError = compiler.CompileError;
pub const CompileOptions = compiler.CompileOptions;

pub const Span = struct {
    start: usize,
    end: usize,
};

pub const MatchIterator = struct {
    dfa: *const Dfa,
    input: []const u8,
    cursor: usize = 0,
    done: bool = false,

    pub fn next(self: *MatchIterator) ?Span {
        if (self.done) return null;
        const span = self.dfa.findAt(self.input, self.cursor) orelse {
            self.done = true;
            return null;
        };
        if (span.end > span.start) {
            self.cursor = span.end;
        } else if (span.end < self.input.len) {
            self.cursor = span.end + 1;
        } else {
            self.done = true;
        }
        return span;
    }
};

const preferred_byte_order: [256]u8 = blk: {
    var order: [256]u8 = undefined;
    var used: [256]bool = @splat(false);
    var idx: usize = 0;

    // 1. Lowercase ASCII letters
    for ('a'..'z' + 1) |b| {
        order[idx] = @intCast(b);
        used[b] = true;
        idx += 1;
    }
    // 2. ASCII digits
    for ('0'..'9' + 1) |b| {
        order[idx] = @intCast(b);
        used[b] = true;
        idx += 1;
    }
    // 3. Uppercase ASCII letters
    for ('A'..'Z' + 1) |b| {
        order[idx] = @intCast(b);
        used[b] = true;
        idx += 1;
    }
    // 4. Remaining printable ASCII
    for (0x20..0x7f) |b| {
        if (!used[b]) {
            order[idx] = @intCast(b);
            used[b] = true;
            idx += 1;
        }
    }
    // 5. Remaining bytes 0..255
    for (0..256) |b| {
        if (!used[b]) {
            order[idx] = @intCast(b);
            used[b] = true;
            idx += 1;
        }
    }
    break :blk order;
};

pub const Dfa = struct {
    num_states: u16,
    table: [MAX_STATES][256]u16,
    accepting: [MAX_STATES]bool,
    anchored_start: bool = false,
    anchored_end: bool = false,

    pub fn init() Dfa {
        var dfa = Dfa{
            .num_states = 2, // 0 = dead, 1 = start
            .table = undefined,
            .accepting = @splat(false),
            .anchored_start = false,
            .anchored_end = false,
        };
        for (0..MAX_STATES) |s| {
            for (0..256) |b| {
                dfa.table[s][b] = DEAD_STATE;
            }
        }
        return dfa;
    }

    pub fn matches(self: *const Dfa, input: []const u8) bool {
        var state: u16 = START_STATE;
        for (input) |b| {
            state = self.table[state][b];
            if (state == DEAD_STATE) return false;
        }
        return self.accepting[state];
    }

    pub fn find(self: *const Dfa, input: []const u8) ?Span {
        return self.findAt(input, 0);
    }

    pub fn findAt(self: *const Dfa, input: []const u8, from_offset: usize) ?Span {
        if (from_offset > input.len) return null;
        if (self.anchored_start and from_offset > 0) return null;

        const max_start: usize = if (self.anchored_start) 0 else input.len;
        var start_idx: usize = from_offset;

        while (true) {
            var state: u16 = START_STATE;
            var last_accept_end: ?usize = null;

            if (self.accepting[state]) {
                if (!self.anchored_end or start_idx == input.len) {
                    last_accept_end = start_idx;
                }
            }

            for (input[start_idx..], 0..) |b, offset| {
                state = self.table[state][b];
                if (state == DEAD_STATE) break;
                if (self.accepting[state]) {
                    const end_pos = start_idx + offset + 1;
                    if (!self.anchored_end or end_pos == input.len) {
                        last_accept_end = end_pos;
                    }
                }
            }

            if (last_accept_end) |end_idx| {
                return Span{ .start = start_idx, .end = end_idx };
            }

            if (start_idx >= max_start) break;
            start_idx += 1;
        }
        return null;
    }

    pub fn matchIterator(self: *const Dfa, input: []const u8) MatchIterator {
        return .{
            .dfa = self,
            .input = input,
        };
    }

    pub fn findAll(self: *const Dfa, input: []const u8, out_spans: []Span) usize {
        var it = self.matchIterator(input);
        var count: usize = 0;
        while (count < out_spans.len) {
            const span = it.next() orelse break;
            out_spans[count] = span;
            count += 1;
        }
        return count;
    }

    pub fn scanCount(self: *const Dfa, input: []const u8) usize {
        var it = self.matchIterator(input);
        var count: usize = 0;
        while (it.next()) |_| {
            count += 1;
        }
        return count;
    }

    pub fn compileWithOptions(pattern: []const u8, options: CompileOptions) CompileError!Dfa {
        var nfa = compiler.Nfa.init();
        const parsed = try compiler.parsePatternIntoNfa(&nfa, pattern, options, true);
        const acc_state = try nfa.addAccept(1);
        nfa.states[parsed.frag.end].out1 = acc_state;

        const compiled = try compiler.determinizeAndMinimize(
            &nfa,
            parsed.frag.start,
            options.minimize,
            null,
        );

        var dfa = Dfa{
            .num_states = compiled.num_states,
            .table = compiled.table,
            .accepting = @splat(false),
            .anchored_start = parsed.anchored_start,
            .anchored_end = parsed.anchored_end,
        };
        for (0..compiled.num_states) |s| {
            dfa.accepting[s] = (compiled.accept_ids[s] != 0);
        }
        return dfa;
    }

    pub fn compileChecked(pattern: []const u8) CompileError!Dfa {
        return compileWithOptions(pattern, .{});
    }

    /// Runtime compilation entry point preserving v0.1.0 signature.
    /// Returns a dead (non-accepting) DFA if pattern compilation fails;
    /// prefer `compileChecked` when explicit syntax/limit diagnostics are needed.
    pub fn compileRuntime(pattern: []const u8) Dfa {
        return compileChecked(pattern) catch Dfa.init();
    }

    pub fn compileComptimeWithOptions(comptime pattern: []const u8, comptime options: CompileOptions) Dfa {
        @setEvalBranchQuota(2_000_000);
        return compileWithOptions(pattern, options) catch |err| {
            @compileError("Alexandrite comptime regex compile failed for \"" ++ pattern ++ "\": " ++ @errorName(err));
        };
    }

    pub fn compile(comptime pattern: []const u8) Dfa {
        return compileComptimeWithOptions(pattern, .{});
    }

    /// Computes the exact number of distinct byte equivalence classes of this DFA.
    pub fn equivClassCount(self: *const Dfa) usize {
        var reps: [256]u8 = undefined;
        var count: usize = 0;

        for (0..256) |b| {
            var matched = false;
            for (0..count) |r| {
                const rep = reps[r];
                var same = true;
                for (0..self.num_states) |s| {
                    if (self.table[s][b] != self.table[s][rep]) {
                        same = false;
                        break;
                    }
                }
                if (same) {
                    matched = true;
                    break;
                }
            }
            if (!matched) {
                reps[count] = @intCast(b);
                count += 1;
            }
        }
        return count;
    }

    /// Returns true if the automaton accepts no strings at all (L(D) == empty set).
    pub fn isEmptyLanguage(self: *const Dfa) bool {
        var visited: [MAX_STATES]bool = @splat(false);
        var queue: [MAX_STATES]u16 = undefined;
        var head: usize = 0;
        var tail: usize = 0;

        visited[START_STATE] = true;
        queue[tail] = START_STATE;
        tail += 1;

        while (head < tail) : (head += 1) {
            const s = queue[head];
            if (self.accepting[s]) return false;
            for (0..256) |b| {
                const nxt = self.table[s][b];
                if (nxt != DEAD_STATE and nxt < self.num_states and !visited[nxt]) {
                    visited[nxt] = true;
                    queue[tail] = nxt;
                    tail += 1;
                }
            }
        }
        return true;
    }

    /// Returns true if the accepted language is finite (no directed cycle on
    /// states that are both reachable from START_STATE and can reach an accepting state).
    pub fn isFiniteLanguage(self: *const Dfa) bool {
        const n: usize = self.num_states;

        // 1. Reachable from START_STATE
        var reachable: [MAX_STATES]bool = @splat(false);
        var queue: [MAX_STATES]u16 = undefined;
        var head: usize = 0;
        var tail: usize = 0;
        reachable[START_STATE] = true;
        queue[tail] = START_STATE;
        tail += 1;

        while (head < tail) : (head += 1) {
            const s = queue[head];
            for (0..256) |b| {
                const nxt = self.table[s][b];
                if (nxt != DEAD_STATE and nxt < n and !reachable[nxt]) {
                    reachable[nxt] = true;
                    queue[tail] = nxt;
                    tail += 1;
                }
            }
        }

        // 2. Co-reachable (can reach an accepting state)
        var coreachable: [MAX_STATES]bool = @splat(false);
        for (0..n) |s| {
            coreachable[s] = self.accepting[s];
        }
        var changed = true;
        while (changed) {
            changed = false;
            for (0..n) |s| {
                if (coreachable[s] or !reachable[s]) continue;
                for (0..256) |b| {
                    const nxt = self.table[s][b];
                    if (nxt < n and coreachable[nxt]) {
                        coreachable[s] = true;
                        changed = true;
                        break;
                    }
                }
            }
        }

        // 3. Build deduplicated live adjacency and check for cycles via Kahn's algorithm
        var live: [MAX_STATES]bool = @splat(false);
        var live_count: usize = 0;
        for (0..n) |s| {
            if (reachable[s] and coreachable[s]) {
                live[s] = true;
                live_count += 1;
            }
        }
        if (live_count == 0) return true;

        var adj: [MAX_STATES][2]u64 = @splat(.{ 0, 0 });
        var indegree: [MAX_STATES]u16 = @splat(0);

        for (0..n) |u| {
            if (!live[u]) continue;
            for (0..256) |b| {
                const v = self.table[u][b];
                if (v >= n or !live[v]) continue;
                if (v == u) return false; // self-loop on a live state => infinite
                const word_idx = v >> 6;
                const bit_mask = @as(u64, 1) << @as(u6, @truncate(v));
                if ((adj[u][word_idx] & bit_mask) == 0) {
                    adj[u][word_idx] |= bit_mask;
                    indegree[v] += 1;
                }
            }
        }

        head = 0;
        tail = 0;
        for (0..n) |s| {
            if (live[s] and indegree[s] == 0) {
                queue[tail] = @intCast(s);
                tail += 1;
            }
        }

        var popped: usize = 0;
        while (head < tail) : (head += 1) {
            const u = queue[head];
            popped += 1;
            for (0..n) |v| {
                if (!live[v]) continue;
                const word_idx = v >> 6;
                const bit_mask = @as(u64, 1) << @as(u6, @truncate(v));
                if ((adj[u][word_idx] & bit_mask) != 0) {
                    indegree[v] -= 1;
                    if (indegree[v] == 0) {
                        queue[tail] = @intCast(v);
                        tail += 1;
                    }
                }
            }
        }

        return popped == live_count;
    }

    /// Decides exact regular-language equivalence L(self) == L(other)
    /// using the Hopcroft-Karp (1971) union-find bisimulation algorithm.
    /// Zero heap allocation; runs at both comptime and runtime.
    pub fn isEquivalentTo(self: *const Dfa, other: *const Dfa) bool {
        const n1: usize = self.num_states;
        const n2: usize = other.num_states;
        const total = n1 + n2;

        var parent: [2 * MAX_STATES]u16 = undefined;
        for (0..total) |i| {
            parent[i] = @intCast(i);
        }

        var q1: [2 * MAX_STATES]u16 = undefined;
        var q2: [2 * MAX_STATES]u16 = undefined;
        var head: usize = 0;
        var tail: usize = 0;

        const r_start1 = ufFind(&parent, START_STATE);
        const r_start2 = ufFind(&parent, @intCast(n1 + START_STATE));
        parent[r_start1] = r_start2;

        q1[tail] = START_STATE;
        q2[tail] = START_STATE;
        tail += 1;

        while (head < tail) : (head += 1) {
            const u = q1[head];
            const v = q2[head];
            if (self.accepting[u] != other.accepting[v]) return false;

            for (0..256) |b| {
                const next_u = self.table[u][b];
                const next_v = other.table[v][b];
                const r1 = ufFind(&parent, next_u);
                const r2 = ufFind(&parent, @intCast(n1 + next_v));
                if (r1 != r2) {
                    parent[r1] = r2;
                    q1[tail] = next_u;
                    q2[tail] = next_v;
                    tail += 1;
                }
            }
        }

        return true;
    }

    fn ufFind(parent: *[2 * MAX_STATES]u16, x_in: u16) u16 {
        var x = x_in;
        while (parent[x] != x) {
            parent[x] = parent[parent[x]];
            x = parent[x];
        }
        return x;
    }

    const ProductMode = enum { symmetric_diff, difference, intersection };

    fn productMatches(self: *const Dfa, other: *const Dfa, u: u16, v: u16, mode: ProductMode) bool {
        return switch (mode) {
            .symmetric_diff => self.accepting[u] != other.accepting[v],
            .difference => self.accepting[u] and !other.accepting[v],
            .intersection => self.accepting[u] and other.accepting[v],
        };
    }

    fn findProductWitness(
        self: *const Dfa,
        other: *const Dfa,
        mode: ProductMode,
        out_buf: []u8,
    ) error{BufferTooSmall}!?[]const u8 {
        if (self.productMatches(other, START_STATE, START_STATE, mode)) {
            return out_buf[0..0];
        }

        const PRODUCT_SIZE = MAX_STATES * MAX_STATES;
        var visited: [PRODUCT_SIZE / 64]u64 = @splat(0);
        var queue: [PRODUCT_SIZE]u16 = undefined;
        var parent_id: [PRODUCT_SIZE]u16 = undefined;
        var via_byte: [PRODUCT_SIZE]u8 = undefined;

        const start_id: u16 = (START_STATE << 7) | START_STATE;
        visited[start_id >> 6] |= (@as(u64, 1) << @as(u6, @truncate(start_id)));
        parent_id[start_id] = start_id;
        via_byte[start_id] = 0;

        var head: usize = 0;
        var tail: usize = 0;
        queue[tail] = start_id;
        tail += 1;

        var found_id: ?u16 = null;
        while (head < tail) : (head += 1) {
            const cur = queue[head];
            const u: u16 = cur >> 7;
            const v: u16 = cur & 0x7f;

            for (preferred_byte_order) |b| {
                const next_u = self.table[u][b];
                const next_v = other.table[v][b];
                const nxt: u16 = (next_u << 7) | next_v;
                const bit = @as(u64, 1) << @as(u6, @truncate(nxt));
                if ((visited[nxt >> 6] & bit) != 0) continue;

                visited[nxt >> 6] |= bit;
                parent_id[nxt] = cur;
                via_byte[nxt] = b;

                if (self.productMatches(other, next_u, next_v, mode)) {
                    found_id = nxt;
                    break;
                }

                queue[tail] = nxt;
                tail += 1;
            }
            if (found_id != null) break;
        }

        const target = found_id orelse return null;

        // Measure witness length
        var len: usize = 0;
        var walk = target;
        while (walk != start_id) {
            len += 1;
            walk = parent_id[walk];
        }
        if (len > out_buf.len) return error.BufferTooSmall;

        // Reconstruct in reverse into out_buf[0..len]
        var idx = len;
        walk = target;
        while (walk != start_id) {
            idx -= 1;
            out_buf[idx] = via_byte[walk];
            walk = parent_id[walk];
        }
        return out_buf[0..len];
    }

    /// Finds a shortest string accepted by exactly one of `self` and `other`,
    /// preferring printable ASCII witnesses among equal-length counterexamples.
    /// Returns `null` if and only if L(self) == L(other).
    pub fn findCounterexample(self: *const Dfa, other: *const Dfa, out_buf: []u8) error{BufferTooSmall}!?[]const u8 {
        if (self.isEquivalentTo(other)) return null;
        return self.findProductWitness(other, .symmetric_diff, out_buf);
    }

    /// Finds a shortest witness in L(self) \ L(other), preferring printable ASCII.
    /// Returns `null` if and only if L(self) ⊆ L(other).
    pub fn findSubsetCounterexample(self: *const Dfa, other: *const Dfa, out_buf: []u8) error{BufferTooSmall}!?[]const u8 {
        return self.findProductWitness(other, .difference, out_buf);
    }

    /// Decides exact regular-language inclusion L(self) ⊆ L(other) with zero heap allocation.
    pub fn isSubsetOf(self: *const Dfa, other: *const Dfa) bool {
        var scratch: [MAX_STATES * MAX_STATES]u8 = undefined;
        return (self.findProductWitness(other, .difference, &scratch) catch return false) == null;
    }

    /// Finds a shortest witness in L(self) ∩ L(other), preferring printable ASCII.
    /// Returns `null` if and only if L(self) ∩ L(other) = ∅.
    pub fn findCommonWitness(self: *const Dfa, other: *const Dfa, out_buf: []u8) error{BufferTooSmall}!?[]const u8 {
        return self.findProductWitness(other, .intersection, out_buf);
    }

    /// Decides exact regular-language disjointness L(self) ∩ L(other) = ∅ with zero heap allocation.
    pub fn isDisjointFrom(self: *const Dfa, other: *const Dfa) bool {
        var scratch: [MAX_STATES * MAX_STATES]u8 = undefined;
        return (self.findProductWitness(other, .intersection, &scratch) catch return false) == null;
    }

    /// Finds a shortest string accepted by `self`, preferring printable ASCII, or `null` if empty.
    pub fn shortestAccepted(self: *const Dfa, out_buf: []u8) error{BufferTooSmall}!?[]const u8 {
        return self.findProductWitness(self, .intersection, out_buf);
    }

    /// Exports the DFA graph in Graphviz DOT format with merged byte-range edge labels.
    pub fn toDot(self: *const Dfa, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("digraph alexandrite_dfa {\n");
        try writer.writeAll("  rankdir=LR;\n");
        try writer.writeAll("  node [shape=circle, fontname=\"monospace\"];\n");
        try writer.writeAll("  edge [fontname=\"monospace\"];\n");
        try writer.writeAll("  __start [shape=point];\n");
        try writer.print("  __start -> s{d};\n", .{START_STATE});

        for (1..self.num_states) |s| {
            if (self.accepting[s]) {
                try writer.print("  s{d} [shape=doublecircle];\n", .{s});
            }
        }

        for (1..self.num_states) |s| {
            var target_seen: [MAX_STATES]bool = @splat(false);
            for (0..256) |b| {
                const t = self.table[s][b];
                if (t == DEAD_STATE or target_seen[t]) continue;
                target_seen[t] = true;

                try writer.print("  s{d} -> s{d} [label=\"", .{ s, t });
                try writeMergedByteLabel(self, s, t, writer, .dot);
                try writer.writeAll("\"];\n");
            }
        }

        try writer.writeAll("}\n");
    }

    /// Exports the DFA metadata and compressed transitions as JSON.
    pub fn toJson(self: *const Dfa, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("{");
        try writer.print("\"num_states\":{d},\"start_state\":{d},\"dead_state\":{d},", .{
            self.num_states,
            START_STATE,
            DEAD_STATE,
        });
        try writer.print("\"equiv_classes\":{d},\"anchored_start\":{},\"anchored_end\":{},", .{
            self.equivClassCount(),
            self.anchored_start,
            self.anchored_end,
        });
        try writer.print("\"empty_language\":{},\"finite_language\":{},\"accepting\":[", .{
            self.isEmptyLanguage(),
            self.isFiniteLanguage(),
        });

        var first_acc = true;
        for (0..self.num_states) |s| {
            if (self.accepting[s]) {
                if (!first_acc) try writer.writeByte(',');
                first_acc = false;
                try writer.print("{d}", .{s});
            }
        }

        try writer.writeAll("],\"transitions\":[");
        var first_edge = true;
        for (1..self.num_states) |s| {
            var target_seen: [MAX_STATES]bool = @splat(false);
            for (0..256) |b| {
                const t = self.table[s][b];
                if (t == DEAD_STATE or target_seen[t]) continue;
                target_seen[t] = true;

                if (!first_edge) try writer.writeByte(',');
                first_edge = false;
                try writer.print("{{\"from\":{d},\"to\":{d},\"label\":\"", .{ s, t });
                try writeMergedByteLabel(self, s, t, writer, .json);
                try writer.writeAll("\"}");
            }
        }
        try writer.writeAll("]}\n");
    }

    const LabelFormat = enum { dot, json };

    fn writeMergedByteLabel(
        self: *const Dfa,
        from_state: usize,
        target_state: u16,
        writer: *std.Io.Writer,
        fmt: LabelFormat,
    ) std.Io.Writer.Error!void {
        var b: usize = 0;
        var first_range = true;
        while (b < 256) {
            if (self.table[from_state][b] != target_state) {
                b += 1;
                continue;
            }
            const lo = b;
            while (b + 1 < 256 and self.table[from_state][b + 1] == target_state) {
                b += 1;
            }
            const hi = b;
            if (!first_range) try writer.writeAll(",");
            first_range = false;

            try writeEscapedByte(@intCast(lo), writer, fmt);
            if (hi > lo) {
                try writer.writeByte('-');
                try writeEscapedByte(@intCast(hi), writer, fmt);
            }
            b += 1;
        }
    }

    fn writeEscapedByte(byte: u8, writer: *std.Io.Writer, fmt: LabelFormat) std.Io.Writer.Error!void {
        _ = fmt;
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\\\n"),
            '\r' => try writer.writeAll("\\\\r"),
            '\t' => try writer.writeAll("\\\\t"),
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try writer.writeByte(byte),
            else => {
                const hex = "0123456789abcdef";
                try writer.writeAll("\\\\x");
                try writer.writeByte(hex[byte >> 4]);
                try writer.writeByte(hex[byte & 0x0f]);
            },
        }
    }
};

// ============================================================================
// Unit & Property Tests
// ============================================================================

test "Comptime DFA Literal Matching" {
    const dfa = comptime Dfa.compile("admin");
    try std.testing.expect(dfa.matches("admin"));
    try std.testing.expect(!dfa.matches("root"));
    try std.testing.expect(!dfa.matches("admi"));
    try std.testing.expect(!dfa.matches("admin1"));
}

test "Comptime DFA Alternation" {
    const dfa = comptime Dfa.compile("GET|POST|DELETE|PATCH");
    try std.testing.expect(dfa.matches("GET"));
    try std.testing.expect(dfa.matches("POST"));
    try std.testing.expect(dfa.matches("DELETE"));
    try std.testing.expect(dfa.matches("PATCH"));
    try std.testing.expect(!dfa.matches("PUT"));
    try std.testing.expect(dfa.isFiniteLanguage());
    try std.testing.expect(!dfa.isEmptyLanguage());
}

test "Comptime DFA SSN PII Scanner" {
    const ssn_dfa = comptime Dfa.compile("\\d\\d\\d-\\d\\d-\\d\\d\\d\\d");
    const ssn_quant = comptime Dfa.compile("\\d{3}-\\d{2}-\\d{4}");
    comptime std.debug.assert(ssn_dfa.isEquivalentTo(&ssn_quant));

    try std.testing.expect(ssn_dfa.matches("123-45-6789"));
    try std.testing.expect(!ssn_dfa.matches("123-45-678a"));

    const log_sample = "User login audit: SSN 987-65-4321 logged from 10.0.0.1";
    const span = ssn_dfa.find(log_sample);
    try std.testing.expect(span != null);
    try std.testing.expectEqualStrings("987-65-4321", log_sample[span.?.start..span.?.end]);
}

test "Comptime DFA Repetition Plus, Star, Optional, and Overlapping Suffixes" {
    const dfa_plus = comptime Dfa.compile("a+b");
    try std.testing.expect(dfa_plus.matches("ab"));
    try std.testing.expect(dfa_plus.matches("aaaab"));
    try std.testing.expect(!dfa_plus.matches("b"));

    // Kleene star (zero or more)
    const dfa_star = comptime Dfa.compile("a*b");
    try std.testing.expect(dfa_star.matches("b"));
    try std.testing.expect(dfa_star.matches("ab"));
    try std.testing.expect(dfa_star.matches("aaaaab"));
    try std.testing.expect(!dfa_star.matches("a"));

    // Optional quantifier
    const dfa_opt = comptime Dfa.compile("colou?r");
    try std.testing.expect(dfa_opt.matches("color"));
    try std.testing.expect(dfa_opt.matches("colour"));
    try std.testing.expect(!dfa_opt.matches("colouur"));

    // Overlapping suffix after +/* (classic Thompson NFA + subset construction test)
    const dfa_overlap = comptime Dfa.compile("a+a");
    try std.testing.expect(!dfa_overlap.matches("a"));
    try std.testing.expect(dfa_overlap.matches("aa"));
    try std.testing.expect(dfa_overlap.matches("aaaaa"));

    const dfa_suffix = comptime Dfa.compile("[a-z]+ab");
    try std.testing.expect(dfa_suffix.matches("aab"));
    try std.testing.expect(dfa_suffix.matches("xyzabab"));
    try std.testing.expect(!dfa_suffix.matches("ab"));
    try std.testing.expect(!dfa_suffix.matches("xyzaba"));
}

test "Groups, Nested Alternation, Bounded Quantifiers, and Negated Classes" {
    const dfa_group = comptime Dfa.compile("(ab|cd)+e?");
    try std.testing.expect(dfa_group.matches("ab"));
    try std.testing.expect(dfa_group.matches("cdabe"));
    try std.testing.expect(dfa_group.matches("ababcdcde"));
    try std.testing.expect(!dfa_group.matches("e"));
    try std.testing.expect(!dfa_group.matches("abce"));

    const dfa_bounds = comptime Dfa.compile("a{2,4}");
    try std.testing.expect(!dfa_bounds.matches("a"));
    try std.testing.expect(dfa_bounds.matches("aa"));
    try std.testing.expect(dfa_bounds.matches("aaa"));
    try std.testing.expect(dfa_bounds.matches("aaaa"));
    try std.testing.expect(!dfa_bounds.matches("aaaaa"));
    try std.testing.expect(dfa_bounds.isFiniteLanguage());

    const dfa_at_least = comptime Dfa.compile("(?:xy){2,}");
    try std.testing.expect(!dfa_at_least.matches("xy"));
    try std.testing.expect(dfa_at_least.matches("xyxy"));
    try std.testing.expect(dfa_at_least.matches("xyxyxy"));
    try std.testing.expect(!dfa_at_least.isFiniteLanguage());

    const dfa_zero_bound = comptime Dfa.compile("a{0}b");
    try std.testing.expect(dfa_zero_bound.matches("b"));
    try std.testing.expect(!dfa_zero_bound.matches("ab"));

    const dfa_neg = comptime Dfa.compile("[^0-9\\s]+");
    try std.testing.expect(dfa_neg.matches("hello_world!"));
    try std.testing.expect(!dfa_neg.matches("hello 1"));
    try std.testing.expect(!dfa_neg.matches("123"));

    // Hex escapes and shorthand negations
    const dfa_hex = comptime Dfa.compile("\\x00\\x7f\\xFF\\D\\W\\S");
    try std.testing.expect(dfa_hex.matches("\x00\x7f\xffA!x"));
    try std.testing.expect(!dfa_hex.matches("\x00\x7f\xff1!x"));
}

test "Inline Flags and Case-Insensitive Negated Classes" {
    const dfa_ci = comptime Dfa.compile("(?i)http|https");
    try std.testing.expect(dfa_ci.matches("HTTP"));
    try std.testing.expect(dfa_ci.matches("Https"));
    try std.testing.expect(dfa_ci.matches("hTtP"));
    try std.testing.expect(!dfa_ci.matches("ftp"));

    const dfa_scoped = comptime Dfa.compile("(?i:get) /api");
    try std.testing.expect(dfa_scoped.matches("GET /api"));
    try std.testing.expect(dfa_scoped.matches("get /api"));
    try std.testing.expect(!dfa_scoped.matches("GET /API"));

    // Negated class under (?i): must reject BOTH 'a' and 'A'
    const dfa_neg_ci = comptime Dfa.compile("(?i)[^a]");
    try std.testing.expect(!dfa_neg_ci.matches("a"));
    try std.testing.expect(!dfa_neg_ci.matches("A"));
    try std.testing.expect(dfa_neg_ci.matches("b"));
    try std.testing.expect(dfa_neg_ci.matches("B"));

    // Dotall flag (?s)
    const dfa_no_s = comptime Dfa.compile("a.b");
    const dfa_with_s = comptime Dfa.compile("(?s)a.b");
    try std.testing.expect(!dfa_no_s.matches("a\nb"));
    try std.testing.expect(dfa_with_s.matches("a\nb"));
}

test "Anchors, Multi-Match Iteration, and Zero-Width Termination" {
    const start_dfa = comptime Dfa.compile("^ERROR");
    try std.testing.expect(start_dfa.find("ERROR: disk full") != null);
    try std.testing.expect(start_dfa.find("INFO: ERROR ignored") == null);

    const end_dfa = comptime Dfa.compile("\\.log$");
    const end_span = end_dfa.find("a.log.bak /var/sys.log");
    try std.testing.expect(end_span != null);
    try std.testing.expectEqualStrings(".log", "a.log.bak /var/sys.log"[end_span.?.start..end_span.?.end]);
    try std.testing.expect(end_dfa.find("a.log.bak") == null);

    const exact_empty = comptime Dfa.compile("^$");
    try std.testing.expect(exact_empty.find("") != null);
    try std.testing.expect(exact_empty.find("x") == null);

    // findAll and scanCount
    const num_dfa = comptime Dfa.compile("\\d+");
    var spans: [8]Span = undefined;
    const text = "port=8080 retries=3 timeout=5000ms";
    const found = num_dfa.findAll(text, &spans);
    try std.testing.expectEqual(@as(usize, 3), found);
    try std.testing.expectEqualStrings("8080", text[spans[0].start..spans[0].end]);
    try std.testing.expectEqualStrings("3", text[spans[1].start..spans[1].end]);
    try std.testing.expectEqualStrings("5000", text[spans[2].start..spans[2].end]);
    try std.testing.expectEqual(@as(usize, 3), num_dfa.scanCount(text));

    // Zero-width match iteration must always terminate cleanly
    const star_dfa = comptime Dfa.compile("a*");
    try std.testing.expectEqual(@as(usize, 2), star_dfa.scanCount("a"));
    try std.testing.expectEqual(@as(usize, 3), star_dfa.scanCount("bb"));
}

test "Hopcroft Minimization Reduces State Count Preserving Language" {
    const unmin = try Dfa.compileWithOptions("(ab|ac|ad)+|(ab|ac|ad){2,}", .{ .minimize = false });
    const min = try Dfa.compileWithOptions("(ab|ac|ad)+|(ab|ac|ad){2,}", .{ .minimize = true });

    try std.testing.expect(min.num_states < unmin.num_states);
    try std.testing.expect(min.isEquivalentTo(&unmin));
    try std.testing.expectEqual(@as(u16, 4), min.num_states); // dead, start, after 'a', accept
}

test "Hopcroft-Karp Equivalence and Shortest Counterexample Witness" {
    const a1 = comptime Dfa.compile("(a|b)*abb");
    const a2 = comptime Dfa.compile("[ab]*a(?:b{2})");
    try std.testing.expect(a1.isEquivalentTo(&a2));

    var witness_buf: [64]u8 = undefined;
    try std.testing.expect((try a1.findCounterexample(&a2, &witness_buf)) == null);

    // Non-equivalent patterns: shortest counterexample for a+ vs a* is ""
    const plus = comptime Dfa.compile("a+");
    const star = comptime Dfa.compile("a*");
    try std.testing.expect(!plus.isEquivalentTo(&star));
    const w1 = (try plus.findCounterexample(&star, &witness_buf)).?;
    try std.testing.expectEqualStrings("", w1);
    try std.testing.expect(plus.matches(w1) != star.matches(w1));

    // Non-equivalent patterns: [a-z]+ vs [a-z]{1,2} -> shortest witness length 3 ("aaa")
    const any_len = comptime Dfa.compile("[a-z]+");
    const max_two = comptime Dfa.compile("[a-z]{1,2}");
    const w2 = (try any_len.findCounterexample(&max_two, &witness_buf)).?;
    try std.testing.expectEqual(@as(usize, 3), w2.len);
    try std.testing.expect(any_len.matches(w2) != max_two.matches(w2));
}

test "CompileError Diagnostics for Malformed Patterns and Resource Limits" {
    try std.testing.expectError(error.UnclosedGroup, Dfa.compileChecked("(abc"));
    try std.testing.expectError(error.UnmatchedClosingParen, Dfa.compileChecked("abc)"));
    try std.testing.expectError(error.UnclosedCharClass, Dfa.compileChecked("[a-z"));
    try std.testing.expectError(error.InvalidCharRange, Dfa.compileChecked("[z-a]"));
    try std.testing.expectError(error.InvalidCharRange, Dfa.compileChecked("[\\d-z]"));
    try std.testing.expectError(error.TrailingBackslash, Dfa.compileChecked("abc\\"));
    try std.testing.expectError(error.InvalidHexEscape, Dfa.compileChecked("\\x1"));
    try std.testing.expectError(error.InvalidHexEscape, Dfa.compileChecked("\\xZZ"));
    try std.testing.expectError(error.InvalidQuantifier, Dfa.compileChecked("+abc"));
    try std.testing.expectError(error.InvalidQuantifier, Dfa.compileChecked("a++"));
    try std.testing.expectError(error.InvalidQuantifier, Dfa.compileChecked("(?i)+"));
    try std.testing.expectError(error.InvalidRepetitionBounds, Dfa.compileChecked("a{5,2}"));
    try std.testing.expectError(error.InvalidRepetitionBounds, Dfa.compileChecked("a{}"));
    try std.testing.expectError(error.RepetitionBoundTooLarge, Dfa.compileChecked("a{999}"));
    try std.testing.expectError(error.UnsupportedAnchor, Dfa.compileChecked("^a|b"));
    try std.testing.expectError(error.UnsupportedAnchor, Dfa.compileChecked("a^b"));
    try std.testing.expectError(error.InvalidInlineFlag, Dfa.compileChecked("(?=foo)"));

    // Deep nesting guard
    try std.testing.expectError(
        error.NestingTooDeep,
        Dfa.compileChecked("((((((((((((((((((((((((((((((((((a))))))))))))))))))))))))))))))))))"),
    );

    // Exhaustive DFA state limit guard: [01]*1[01]{7} requires 2^8 = 256 minimal states > MAX_STATES(128)
    try std.testing.expectError(error.DfaStateLimitExceeded, Dfa.compileChecked("[01]*1[01]{7}"));
}

test "DOT and JSON Serialization" {
    const dfa = comptime Dfa.compile("[0-9]+");
    var dot_buf: [1024]u8 = undefined;
    var dot_writer = std.Io.Writer.fixed(&dot_buf);
    try dfa.toDot(&dot_writer);
    const dot_out = dot_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, dot_out, "digraph alexandrite_dfa") != null);
    try std.testing.expect(std.mem.indexOf(u8, dot_out, "0-9") != null);
    try std.testing.expect(std.mem.indexOf(u8, dot_out, "doublecircle") != null);

    var json_buf: [1024]u8 = undefined;
    var json_writer = std.Io.Writer.fixed(&json_buf);
    try dfa.toJson(&json_writer);
    const json_out = json_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, json_out, "\"num_states\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_out, "\"finite_language\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_out, "\"label\":\"0-9\"") != null);

    // Validate strict RFC 8259 JSON with quotes, backslashes, newlines, and binary bytes
    const tricky = comptime Dfa.compile("[\"\\\\\\n\\x00\\xff]+");
    var tricky_buf: [2048]u8 = undefined;
    var tricky_writer = std.Io.Writer.fixed(&tricky_buf);
    try tricky.toJson(&tricky_writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, tricky_writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("num_states").?.integer);
}

test "Empty Language and Edge-Case Character Classes" {
    // Negating all 256 bytes yields the empty language
    const empty_lang = comptime Dfa.compile("[^\\x00-\\xff]");
    try std.testing.expect(empty_lang.isEmptyLanguage());
    try std.testing.expect(empty_lang.isFiniteLanguage());
    try std.testing.expectEqual(@as(u16, 2), empty_lang.num_states);
    try std.testing.expect(!empty_lang.matches(""));
    try std.testing.expect(!empty_lang.matches("a"));
    try std.testing.expect(empty_lang.find("abc") == null);

    // Leading ']' and '-' and trailing '-' in character classes
    const special_cls = comptime Dfa.compile("[]a-]+");
    try std.testing.expect(special_cls.matches("]-a-"));
    try std.testing.expect(!special_cls.matches("b"));

    const lead_dash = comptime Dfa.compile("[-z]+");
    try std.testing.expect(lead_dash.matches("-z-"));
    try std.testing.expect(!lead_dash.matches("a"));

    // Empty alternation branches & nested empty star cycles
    const opt_branch = comptime Dfa.compile("a|");
    const opt_q = comptime Dfa.compile("a?");
    try std.testing.expect(opt_branch.isEquivalentTo(&opt_q));

    const empty_cycles = comptime Dfa.compile("(|a*)*");
    const a_star = comptime Dfa.compile("a*");
    try std.testing.expect(empty_cycles.isEquivalentTo(&a_star));
}

test "Property Test: Minimization Preserves Exact Language Across Diverse Patterns" {
    const patterns = [_][]const u8{
        "(a|b)*abb",
        "(ab|cd|ef)+|(ab|cd){2,4}",
        "(0|1)*1(0|1){3}",
        "([a-z]+_)*[0-9]{1,3}",
        "(?i)(get|post|put|delete|patch)",
        "(a?){4}a{4}",
        "[^a-z]*[a-z]{2,3}[^a-z]*",
    };

    for (patterns) |pat| {
        const unmin = try Dfa.compileWithOptions(pat, .{ .minimize = false });
        const min = try Dfa.compileWithOptions(pat, .{ .minimize = true });
        try std.testing.expect(min.num_states <= unmin.num_states);
        try std.testing.expect(min.isEquivalentTo(&unmin));
        try std.testing.expectEqual(unmin.isEmptyLanguage(), min.isEmptyLanguage());
        try std.testing.expectEqual(unmin.isFiniteLanguage(), min.isFiniteLanguage());
    }
}

test "Property Test: NFA-Derived DFA Matches Reference Brute-Force Semantics Over All Binary Strings" {
    // Verify DFA compiled from complex regex matches an independent ground-truth predicate
    // on every binary string of length 0..10 (2047 strings).
    const pattern = "(0|1)*1(0|1){2}"; // 3rd-from-last bit is '1'
    const dfa = try Dfa.compileChecked(pattern);
    try std.testing.expectEqual(@as(u16, 9), dfa.num_states); // 2^3 = 8 live states + 1 dead = 9

    var buf: [10]u8 = undefined;
    for (0..11) |len| {
        const total: usize = @as(usize, 1) << @intCast(len);
        for (0..total) |mask| {
            for (0..len) |i| {
                buf[i] = if (((mask >> @intCast(i)) & 1) != 0) '1' else '0';
            }
            const s = buf[0..len];
            const expected = (len >= 3 and s[len - 3] == '1');
            try std.testing.expectEqual(expected, dfa.matches(s));
        }
    }
}
