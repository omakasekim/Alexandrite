const std = @import("std");
pub const compiler = @import("compiler.zig");
pub const dfa = @import("dfa.zig");
pub const lexer = @import("lexer.zig");
pub const wasm = @import("wasm.zig");

const Dfa = dfa.Dfa;
const CompileOptions = compiler.CompileOptions;
const VERSION = "0.3.0";

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    var args = init.minimal.args.iterate();
    _ = args.next(); // skip program name

    const cmd = args.next() orelse {
        try printUsage(stdout);
        try stdout.flush();
        return;
    };

    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        try printUsage(stdout);
        try stdout.flush();
        return;
    } else if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V") or std.mem.eql(u8, cmd, "version")) {
        try stdout.print("alexandrite {s}\n", .{VERSION});
        try stdout.flush();
        return;
    } else if (std.mem.eql(u8, cmd, "match")) {
        const ok = try cmdMatch(&args, stdout, stderr);
        try stdout.flush();
        try stderr.flush();
        if (!ok) std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "find")) {
        const ok = try cmdFind(&args, stdout, stderr);
        try stdout.flush();
        try stderr.flush();
        if (!ok) std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "dump")) {
        const ok = try cmdDump(&args, stdout, stderr);
        try stdout.flush();
        try stderr.flush();
        if (!ok) std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "equiv")) {
        const ok = try cmdEquiv(&args, stdout, stderr);
        try stdout.flush();
        try stderr.flush();
        if (!ok) std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "subset")) {
        const ok = try cmdSubset(&args, stdout, stderr);
        try stdout.flush();
        try stderr.flush();
        if (!ok) std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "disjoint")) {
        const ok = try cmdDisjoint(&args, stdout, stderr);
        try stdout.flush();
        try stderr.flush();
        if (!ok) std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "lex")) {
        const ok = try cmdLex(&args, stdout, stderr);
        try stdout.flush();
        try stderr.flush();
        if (!ok) std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "bench")) {
        try cmdBench(&args, init.io, stdout);
        try stdout.flush();
    } else {
        try stderr.print("Error: unknown subcommand '{s}'\n\n", .{cmd});
        try printUsage(stderr);
        try stderr.flush();
        std.process.exit(2);
    }
}

fn cmdMatch(args: anytype, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    var json_mode = false;
    var opts = CompileOptions{};
    var pos_args: [2][]const u8 = undefined;
    var pos_count: usize = 0;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
            opts.case_insensitive = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--dotall")) {
            opts.dot_matches_newline = true;
        } else if (pos_count < 2) {
            pos_args[pos_count] = arg;
            pos_count += 1;
        }
    }

    if (pos_count < 2) {
        try stderr.writeAll("Error: usage: alexandrite match [--json] [-i] [-s] <pattern> <text>\n");
        return false;
    }

    const pattern = pos_args[0];
    const text = pos_args[1];
    const d = Dfa.compileWithOptions(pattern, opts) catch |err| {
        try stderr.print("Compile error for pattern '{s}': {s}\n", .{ pattern, @errorName(err) });
        return false;
    };

    const matched = d.matches(text);
    if (json_mode) {
        try stdout.writeAll("{\"matched\":");
        try stdout.print("{},\"states\":{d},\"equiv_classes\":{d},\"pattern\":", .{
            matched,
            d.num_states,
            d.equivClassCount(),
        });
        try writeJsonString(stdout, pattern);
        try stdout.writeAll("}\n");
    } else if (matched) {
        try stdout.print("MATCH: text matches pattern '{s}' (states: {d})\n", .{ pattern, d.num_states });
    } else {
        try stdout.print("NO MATCH: text does not match pattern '{s}' (states: {d})\n", .{ pattern, d.num_states });
    }
    return true;
}

fn cmdFind(args: anytype, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    var json_mode = false;
    var find_all = false;
    var opts = CompileOptions{};
    var pos_args: [2][]const u8 = undefined;
    var pos_count: usize = 0;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            find_all = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
            opts.case_insensitive = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--dotall")) {
            opts.dot_matches_newline = true;
        } else if (pos_count < 2) {
            pos_args[pos_count] = arg;
            pos_count += 1;
        }
    }

    if (pos_count < 2) {
        try stderr.writeAll("Error: usage: alexandrite find [--all] [--json] [-i] [-s] <pattern> <text>\n");
        return false;
    }

    const pattern = pos_args[0];
    const text = pos_args[1];
    const d = Dfa.compileWithOptions(pattern, opts) catch |err| {
        try stderr.print("Compile error for pattern '{s}': {s}\n", .{ pattern, @errorName(err) });
        return false;
    };

    if (find_all) {
        var it = d.matchIterator(text);
        if (json_mode) {
            const total = d.scanCount(text);
            try stdout.print("{{\"count\":{d},\"matches\":[", .{total});
            var first = true;
            while (it.next()) |span| {
                if (!first) try stdout.writeByte(',');
                first = false;
                try stdout.print("{{\"start\":{d},\"end\":{d},\"text\":", .{ span.start, span.end });
                try writeJsonString(stdout, text[span.start..span.end]);
                try stdout.writeByte('}');
            }
            try stdout.writeAll("]}\n");
        } else {
            var count: usize = 0;
            while (it.next()) |span| {
                count += 1;
                try stdout.print("MATCH #{d} at [{d}..{d}]: '{s}'\n", .{
                    count,
                    span.start,
                    span.end,
                    text[span.start..span.end],
                });
            }
            if (count == 0) {
                try stdout.writeAll("NOT FOUND\n");
            }
        }
    } else {
        const span_opt = d.find(text);
        if (json_mode) {
            if (span_opt) |span| {
                try stdout.print("{{\"found\":true,\"start\":{d},\"end\":{d},\"text\":", .{ span.start, span.end });
                try writeJsonString(stdout, text[span.start..span.end]);
                try stdout.writeAll("}\n");
            } else {
                try stdout.writeAll("{\"found\":false}\n");
            }
        } else if (span_opt) |span| {
            try stdout.print("FOUND at [{d}..{d}]: '{s}'\n", .{ span.start, span.end, text[span.start..span.end] });
        } else {
            try stdout.writeAll("NOT FOUND\n");
        }
    }
    return true;
}

fn cmdDump(args: anytype, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    const Mode = enum { text, dot, json };
    var mode: Mode = .text;
    var opts = CompileOptions{};
    var pattern_opt: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dot")) {
            mode = .dot;
        } else if (std.mem.eql(u8, arg, "--json")) {
            mode = .json;
        } else if (std.mem.eql(u8, arg, "--no-minimize")) {
            opts.minimize = false;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
            opts.case_insensitive = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--dotall")) {
            opts.dot_matches_newline = true;
        } else if (pattern_opt == null) {
            pattern_opt = arg;
        }
    }

    const pattern = pattern_opt orelse {
        try stderr.writeAll("Error: usage: alexandrite dump [--dot|--json] [--no-minimize] [-i] [-s] <pattern>\n");
        return false;
    };

    const d = Dfa.compileWithOptions(pattern, opts) catch |err| {
        try stderr.print("Compile error for pattern '{s}': {s}\n", .{ pattern, @errorName(err) });
        return false;
    };

    switch (mode) {
        .dot => try d.toDot(stdout),
        .json => try d.toJson(stdout),
        .text => {
            try stdout.print("DFA for pattern: '{s}'\n", .{pattern});
            try stdout.print("Total States: {d} (minimized: {})\n", .{ d.num_states, opts.minimize });
            try stdout.print("Byte Equivalence Classes: {d}\n", .{d.equivClassCount()});
            try stdout.print("Anchors: start={}, end={}\n", .{ d.anchored_start, d.anchored_end });
            try stdout.print("Language: empty={}, finite={}\n", .{ d.isEmptyLanguage(), d.isFiniteLanguage() });
            try stdout.writeAll("Accepting States: ");
            for (0..d.num_states) |s| {
                if (d.accepting[s]) {
                    try stdout.print("{d} ", .{s});
                }
            }
            try stdout.writeByte('\n');

            try stdout.writeAll("Transitions:\n");
            for (1..d.num_states) |s| {
                var seen: [dfa.MAX_STATES]bool = @splat(false);
                for (0..256) |b| {
                    const t = d.table[s][b];
                    if (t == dfa.DEAD_STATE or seen[t]) continue;
                    seen[t] = true;
                    try stdout.print("  s{d} -> s{d} on [", .{ s, t });
                    var first = true;
                    var ch: usize = 0;
                    while (ch < 256) {
                        if (d.table[s][ch] != t) {
                            ch += 1;
                            continue;
                        }
                        const lo = ch;
                        while (ch + 1 < 256 and d.table[s][ch + 1] == t) ch += 1;
                        const hi = ch;
                        if (!first) try stdout.writeAll(", ");
                        first = false;
                        try writeDisplayByte(stdout, @intCast(lo));
                        if (hi > lo) {
                            try stdout.writeByte('-');
                            try writeDisplayByte(stdout, @intCast(hi));
                        }
                        ch += 1;
                    }
                    try stdout.writeAll("]\n");
                }
            }
        },
    }
    return true;
}

fn cmdEquiv(args: anytype, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    var json_mode = false;
    var opts = CompileOptions{};
    var pos_args: [2][]const u8 = undefined;
    var pos_count: usize = 0;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
            opts.case_insensitive = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--dotall")) {
            opts.dot_matches_newline = true;
        } else if (pos_count < 2) {
            pos_args[pos_count] = arg;
            pos_count += 1;
        }
    }

    if (pos_count < 2) {
        try stderr.writeAll("Error: usage: alexandrite equiv [--json] [-i] [-s] <pattern1> <pattern2>\n");
        return false;
    }

    const p1 = pos_args[0];
    const p2 = pos_args[1];

    const d1 = Dfa.compileWithOptions(p1, opts) catch |err| {
        try stderr.print("Compile error for pattern 1 '{s}': {s}\n", .{ p1, @errorName(err) });
        return false;
    };
    const d2 = Dfa.compileWithOptions(p2, opts) catch |err| {
        try stderr.print("Compile error for pattern 2 '{s}': {s}\n", .{ p2, @errorName(err) });
        return false;
    };

    var witness_buf: [512]u8 = undefined;
    const witness_opt = d1.findCounterexample(&d2, &witness_buf) catch null;
    const equivalent = d1.isEquivalentTo(&d2);

    if (json_mode) {
        try stdout.print("{{\"equivalent\":{},\"states_a\":{d},\"states_b\":{d}", .{
            equivalent,
            d1.num_states,
            d2.num_states,
        });
        if (!equivalent) {
            if (witness_opt) |w| {
                try stdout.writeAll(",\"counterexample\":");
                try writeJsonString(stdout, w);
                try stdout.print(",\"accepted_by_a\":{},\"accepted_by_b\":{}", .{
                    d1.matches(w),
                    d2.matches(w),
                });
            }
        }
        try stdout.writeAll("}\n");
    } else if (equivalent) {
        try stdout.print("EQUIVALENT: L('{s}') == L('{s}') (minimal states: {d}, {d})\n", .{
            p1,
            p2,
            d1.num_states,
            d2.num_states,
        });
    } else {
        try stdout.print("NOT EQUIVALENT: L('{s}') != L('{s}')\n", .{ p1, p2 });
        if (witness_opt) |w| {
            try stdout.writeAll("Shortest counterexample: \"");
            for (w) |b| try writeDisplayByte(stdout, b);
            try stdout.print("\" (len={d}; pattern1={}, pattern2={})\n", .{
                w.len,
                d1.matches(w),
                d2.matches(w),
            });
        }
    }
    return true;
}

fn cmdSubset(args: anytype, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    var json_mode = false;
    var opts = CompileOptions{};
    var pos_args: [2][]const u8 = undefined;
    var pos_count: usize = 0;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
            opts.case_insensitive = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--dotall")) {
            opts.dot_matches_newline = true;
        } else if (pos_count < 2) {
            pos_args[pos_count] = arg;
            pos_count += 1;
        }
    }

    if (pos_count < 2) {
        try stderr.writeAll("Error: usage: alexandrite subset [--json] [-i] [-s] <pattern1> <pattern2>\n");
        return false;
    }

    const p1 = pos_args[0];
    const p2 = pos_args[1];
    const d1 = Dfa.compileWithOptions(p1, opts) catch |err| {
        try stderr.print("Compile error for pattern 1 '{s}': {s}\n", .{ p1, @errorName(err) });
        return false;
    };
    const d2 = Dfa.compileWithOptions(p2, opts) catch |err| {
        try stderr.print("Compile error for pattern 2 '{s}': {s}\n", .{ p2, @errorName(err) });
        return false;
    };

    var witness_buf: [512]u8 = undefined;
    const witness_opt = d1.findSubsetCounterexample(&d2, &witness_buf) catch null;
    const subset = d1.isSubsetOf(&d2);

    if (json_mode) {
        try stdout.print("{{\"subset\":{},\"states_a\":{d},\"states_b\":{d}", .{ subset, d1.num_states, d2.num_states });
        if (!subset) {
            if (witness_opt) |w| {
                try stdout.writeAll(",\"counterexample\":");
                try writeJsonString(stdout, w);
            }
        }
        try stdout.writeAll("}\n");
    } else if (subset) {
        try stdout.print("SUBSET: L('{s}') <= L('{s}')\n", .{ p1, p2 });
    } else {
        try stdout.print("NOT SUBSET: L('{s}') is not contained in L('{s}')\n", .{ p1, p2 });
        if (witness_opt) |w| {
            try stdout.writeAll("Shortest counterexample: \"");
            for (w) |b| try writeDisplayByte(stdout, b);
            try stdout.print("\" (len={d})\n", .{w.len});
        }
    }
    return true;
}

fn cmdDisjoint(args: anytype, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    var json_mode = false;
    var opts = CompileOptions{};
    var pos_args: [2][]const u8 = undefined;
    var pos_count: usize = 0;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
            opts.case_insensitive = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--dotall")) {
            opts.dot_matches_newline = true;
        } else if (pos_count < 2) {
            pos_args[pos_count] = arg;
            pos_count += 1;
        }
    }

    if (pos_count < 2) {
        try stderr.writeAll("Error: usage: alexandrite disjoint [--json] [-i] [-s] <pattern1> <pattern2>\n");
        return false;
    }

    const p1 = pos_args[0];
    const p2 = pos_args[1];
    const d1 = Dfa.compileWithOptions(p1, opts) catch |err| {
        try stderr.print("Compile error for pattern 1 '{s}': {s}\n", .{ p1, @errorName(err) });
        return false;
    };
    const d2 = Dfa.compileWithOptions(p2, opts) catch |err| {
        try stderr.print("Compile error for pattern 2 '{s}': {s}\n", .{ p2, @errorName(err) });
        return false;
    };

    var witness_buf: [512]u8 = undefined;
    const witness_opt = d1.findCommonWitness(&d2, &witness_buf) catch null;
    const disjoint = d1.isDisjointFrom(&d2);

    if (json_mode) {
        try stdout.print("{{\"disjoint\":{},\"states_a\":{d},\"states_b\":{d}", .{ disjoint, d1.num_states, d2.num_states });
        if (!disjoint) {
            if (witness_opt) |w| {
                try stdout.writeAll(",\"witness\":");
                try writeJsonString(stdout, w);
            }
        }
        try stdout.writeAll("}\n");
    } else if (disjoint) {
        try stdout.print("DISJOINT: L('{s}') & L('{s}') == empty\n", .{ p1, p2 });
    } else {
        try stdout.print("OVERLAPPING: L('{s}') & L('{s}') != empty\n", .{ p1, p2 });
        if (witness_opt) |w| {
            try stdout.writeAll("Shortest shared string: \"");
            for (w) |b| try writeDisplayByte(stdout, b);
            try stdout.print("\" (len={d})\n", .{w.len});
        }
    }
    return true;
}

fn cmdLex(args: anytype, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    var json_mode = false;
    var input_opt: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (input_opt == null) {
            input_opt = arg;
        }
    }

    const input = input_opt orelse {
        try stderr.writeAll("Error: usage: alexandrite lex [--json] <source>\n");
        return false;
    };

    const cl = &lexer.default_code_lexer;
    var it = cl.iterator(input);

    if (json_mode) {
        try stdout.print("{{\"lexer_states\":{d},\"tokens\":[", .{cl.num_states});
        var first = true;
        while (it.next()) |tok| {
            if (!first) try stdout.writeByte(',');
            first = false;
            try stdout.print("{{\"type\":\"{s}\",\"line\":{d},\"column\":{d},\"start\":{d},\"end\":{d},\"lexeme\":", .{
                @tagName(tok.token_type),
                tok.line,
                tok.column,
                tok.start,
                tok.end,
            });
            try writeJsonString(stdout, tok.lexeme(input));
            try stdout.writeByte('}');
        }
        try stdout.writeAll("]}\n");
    } else {
        try stdout.print("Compiled single-pass lexer DFA ({d} minimal states):\n", .{cl.num_states});
        while (it.next()) |tok| {
            try stdout.print("  {d}:{d}\t[{d}..{d}]\t{s}\t", .{
                tok.line,
                tok.column,
                tok.start,
                tok.end,
                @tagName(tok.token_type),
            });
            try writeJsonString(stdout, tok.lexeme(input));
            try stdout.writeByte('\n');
        }
    }
    return true;
}

const BenchResult = struct {
    name: []const u8,
    states: u16,
    units: usize,
    elapsed_ms: f64,
    mb_per_sec: f64,
};

fn runDfaBench(
    io: std.Io,
    name: []const u8,
    d: *const Dfa,
    sample: []const u8,
    iterations: usize,
) BenchResult {
    var matches: usize = 0;
    const ts_start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        if (d.find(sample)) |span| {
            matches +%= span.end - span.start;
        }
    }
    const ts_end = std.Io.Clock.Timestamp.now(io, .awake);
    const elapsed_ns = @max(@as(i96, 1), ts_start.durationTo(ts_end).raw.nanoseconds);
    const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const total_bytes: f64 = @floatFromInt(sample.len * iterations);

    return .{
        .name = name,
        .states = d.num_states,
        .units = matches,
        .elapsed_ms = elapsed_sec * 1000.0,
        .mb_per_sec = (total_bytes / (1024.0 * 1024.0)) / elapsed_sec,
    };
}

fn runLexerBench(
    io: std.Io,
    name: []const u8,
    cl: *const lexer.CompiledLexer,
    sample: []const u8,
    iterations: usize,
) BenchResult {
    var tokens: usize = 0;
    const ts_start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        tokens +%= cl.countTokens(sample);
    }
    const ts_end = std.Io.Clock.Timestamp.now(io, .awake);
    const elapsed_ns = @max(@as(i96, 1), ts_start.durationTo(ts_end).raw.nanoseconds);
    const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const total_bytes: f64 = @floatFromInt(sample.len * iterations);

    return .{
        .name = name,
        .states = cl.num_states,
        .units = tokens,
        .elapsed_ms = elapsed_sec * 1000.0,
        .mb_per_sec = (total_bytes / (1024.0 * 1024.0)) / elapsed_sec,
    };
}

fn cmdBench(args: anytype, io: std.Io, stdout: *std.Io.Writer) !void {
    var json_mode = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        }
    }

    const ssn_dfa = comptime Dfa.compile("\\d{3}-\\d{2}-\\d{4}");
    const http_dfa = comptime Dfa.compile("(?:GET|POST|PUT|DELETE|PATCH) /api/v\\d+/[a-z0-9_-]+");
    const log_dfa = comptime Dfa.compile("(?i)(?:error|warn|fatal): [a-z0-9_]+");

    const ssn_sample = "2026-11-08 12:00:00 [AUDIT] user_id=9876 ssn=123-45-6789 event=login_success\n";
    const http_sample = "10.0.0.42 - - \"POST /api/v2/audit_records HTTP/1.1\" 201 512\n";
    const log_sample = "2026-11-08T12:01:22Z [worker-7] ERROR: connection_timeout retry=3\n";
    const lex_sample = "pub fn compute(x, y) -> 42.5 { const z = x + y; if z >= 10 return z; }\n";

    const iterations: usize = 100_000;
    const results = [_]BenchResult{
        runDfaBench(io, "ssn_pii_scanner", &ssn_dfa, ssn_sample, iterations),
        runDfaBench(io, "http_route_scanner", &http_dfa, http_sample, iterations),
        runDfaBench(io, "case_insensitive_log", &log_dfa, log_sample, iterations),
        runLexerBench(io, "single_pass_code_lexer", &lexer.default_code_lexer, lex_sample, iterations),
    };

    if (json_mode) {
        try stdout.print("{{\"iterations\":{d},\"benchmarks\":[", .{iterations});
        for (results, 0..) |r, i| {
            if (i > 0) try stdout.writeByte(',');
            try stdout.print("{{\"name\":\"{s}\",\"states\":{d},\"units\":{d},\"elapsed_ms\":{d:.2},\"mb_per_sec\":{d:.2}}}", .{
                r.name,
                r.states,
                r.units,
                r.elapsed_ms,
                r.mb_per_sec,
            });
        }
        try stdout.writeAll("]}\n");
    } else {
        try stdout.print("Benchmarking comptime-compiled zero-allocation DFAs ({d} iterations each):\n", .{iterations});
        for (results) |r| {
            try stdout.print("  {s:<24} states={d:<3} elapsed={d:>7.2} ms  throughput={d:>8.2} MB/s\n", .{
                r.name,
                r.states,
                r.elapsed_ms,
                r.mb_per_sec,
            });
        }
    }
}

fn writeDisplayByte(writer: *std.Io.Writer, b: u8) !void {
    switch (b) {
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x20...0x7e => try writer.writeByte(b),
        else => {
            const hex = "0123456789abcdef";
            try writer.writeAll("\\x");
            try writer.writeByte(hex[b >> 4]);
            try writer.writeByte(hex[b & 0x0f]);
        },
    }
}

fn writeJsonString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');
    const hex = "0123456789abcdef";
    for (bytes) |b| {
        switch (b) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try writer.writeByte(b),
            else => {
                try writer.writeAll("\\u00");
                try writer.writeByte(hex[b >> 4]);
                try writer.writeByte(hex[b & 0x0f]);
            },
        }
    }
    try writer.writeByte('"');
}

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Alexandrite: Compile-Time & Runtime DFA Regular Expression and Lexer Engine
        \\
        \\Usage:
        \\  alexandrite match [--json] [-i] [-s] <pattern> <text>
        \\  alexandrite find [--all] [--json] [-i] [-s] <pattern> <text>
        \\  alexandrite dump [--dot|--json] [--no-minimize] [-i] [-s] <pattern>
        \\  alexandrite equiv [--json] [-i] [-s] <pattern1> <pattern2>
        \\  alexandrite subset [--json] [-i] [-s] <pattern1> <pattern2>
        \\  alexandrite disjoint [--json] [-i] [-s] <pattern1> <pattern2>
        \\  alexandrite lex [--json] <source>
        \\  alexandrite bench [--json]
        \\  alexandrite --version
        \\  alexandrite --help
        \\
    );
}

test {
    _ = @import("compiler.zig");
    _ = @import("dfa.zig");
    _ = @import("lexer.zig");
    _ = @import("wasm.zig");
}

test "v0.3.0 language inclusion, disjointness, and shortest witness" {
    const digits = try Dfa.compileWithOptions("[0-9]+", .{});
    const alnum = try Dfa.compileWithOptions("[a-z0-9]+", .{});
    const letters = try Dfa.compileWithOptions("[a-z]+", .{});
    const ab_plus = try Dfa.compileWithOptions("a+b+", .{});

    try std.testing.expect(digits.isSubsetOf(&alnum));
    try std.testing.expect(!alnum.isSubsetOf(&digits));

    var buf: [64]u8 = undefined;
    const sub_w = (try alnum.findSubsetCounterexample(&digits, &buf)).?;
    try std.testing.expect(alnum.matches(sub_w));
    try std.testing.expect(!digits.matches(sub_w));

    try std.testing.expect(digits.isDisjointFrom(&letters));
    try std.testing.expect(!alnum.isDisjointFrom(&letters));
    const common = (try alnum.findCommonWitness(&letters, &buf)).?;
    try std.testing.expect(alnum.matches(common) and letters.matches(common));

    const shortest = (try ab_plus.shortestAccepted(&buf)).?;
    try std.testing.expectEqualStrings("ab", shortest);
}
