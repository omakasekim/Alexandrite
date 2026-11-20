const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Reusable library module for downstream Zig packages
    _ = b.addModule("alexandrite", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Native CLI tool
    const exe = b.addExecutable(.{
        .name = "alexandrite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Freestanding WebAssembly artifact
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm = b.addExecutable(.{
        .name = "alexandrite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    wasm.entry = .disabled;
    wasm.root_module.export_symbol_names = &.{
        // Core v0.1.0 ABI (preserved for backward compatibility)
        "alexandrite_get_buffer",
        "alexandrite_compile",
        "alexandrite_matches",
        "alexandrite_find_start",
        "alexandrite_find_end",
        "alexandrite_get_states",
        "alexandrite_is_accepting",
        "alexandrite_get_transition",
        // Extended introspection, flags, and multi-match ABI
        "alexandrite_get_buffer_capacity",
        "alexandrite_get_last_error",
        "alexandrite_compile_flags",
        "alexandrite_scan_count",
        "alexandrite_find_from",
        "alexandrite_last_match_end",
        "alexandrite_get_equiv_classes",
        "alexandrite_is_empty_language",
        "alexandrite_is_finite_language",
    };
    const install_wasm = b.addInstallArtifact(wasm, .{});
    b.getInstallStep().dependOn(&install_wasm.step);

    const wasm_step = b.step("wasm", "Build freestanding WebAssembly module");
    wasm_step.dependOn(&install_wasm.step);

    // Test runner
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
