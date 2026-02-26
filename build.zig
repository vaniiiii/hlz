const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Dependencies ─────────────────────────────────────────────────
    const websocket_dep = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    // ── Core library module ──────────────────────────────────────────
    const hyperzig = b.addModule("hyperzig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "websocket", .module = websocket_dep.module("websocket") },
        },
    });

    // ── Unit tests (from source modules) ─────────────────────────────
    const unit_tests = b.addTest(.{
        .root_module = hyperzig,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // ── Integration tests ────────────────────────────────────────────
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hyperzig", .module = hyperzig },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    // ── Test step ────────────────────────────────────────────────────
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // ── Benchmarks ───────────────────────────────────────────────────
    const bench_step = b.step("bench", "Run benchmarks");
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "hyperzig", .module = hyperzig },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    bench_step.dependOn(&run_bench.step);

    // ── End-to-end tests (live API executable) ───────────────────────
    const e2e_step = b.step("e2e", "Run end-to-end tests against live Hyperliquid APIs");
    const e2e = b.addExecutable(.{
        .name = "e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hyperzig", .module = hyperzig },
            },
        }),
    });
    const run_e2e = b.addRunArtifact(e2e);
    if (b.args) |args| run_e2e.addArgs(args);
    e2e_step.dependOn(&run_e2e.step);

    // ── Examples ─────────────────────────────────────────────────────
    const example_step = b.step("example", "Run place_order example");
    const example = b.addExecutable(.{
        .name = "place_order",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/place_order.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hyperzig", .module = hyperzig },
            },
        }),
    });
    const run_example = b.addRunArtifact(example);
    example_step.dependOn(&run_example.step);

    // ── TUI modules ───────────────────────────────────────────────────
    const tui_buffer = b.addModule("tui_buffer", .{
        .root_source_file = b.path("src/tui/Buffer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tui_terminal = b.addModule("tui_terminal", .{
        .root_source_file = b.path("src/tui/Terminal.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tui_layout = b.addModule("tui_layout", .{
        .root_source_file = b.path("src/tui/Layout.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "Buffer.zig", .module = tui_buffer },
        },
    });
    const tui_list = b.addModule("tui_list", .{
        .root_source_file = b.path("src/tui/List.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "Buffer.zig", .module = tui_buffer },
            .{ .name = "Terminal.zig", .module = tui_terminal },
        },
    });
    const tui_app = b.addModule("tui_app", .{
        .root_source_file = b.path("src/tui/App.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "Terminal.zig", .module = tui_terminal },
            .{ .name = "Buffer.zig", .module = tui_buffer },
        },
    });

    // ── TUI tests ─────────────────────────────────────────────────────
    const tui_layout_test = b.addTest(.{ .root_module = tui_layout });
    const tui_list_test = b.addTest(.{ .root_module = tui_list });
    test_step.dependOn(&b.addRunArtifact(tui_layout_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_list_test).step);

    // ── TUI demo ──────────────────────────────────────────────────────
    const tui_demo_step = b.step("tui-demo", "Run TUI demo");
    const tui_demo = b.addExecutable(.{
        .name = "tui-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tui_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Terminal", .module = tui_terminal },
                .{ .name = "Buffer", .module = tui_buffer },
            },
        }),
    });
    const run_tui_demo = b.addRunArtifact(tui_demo);
    tui_demo_step.dependOn(&run_tui_demo.step);

    // ── CLI executable (`hl`) ────────────────────────────────────────
    const hl = b.addExecutable(.{
        .name = "hl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hyperzig", .module = hyperzig },
                .{ .name = "Terminal", .module = tui_terminal },
                .{ .name = "Buffer", .module = tui_buffer },
                .{ .name = "Layout", .module = tui_layout },
                .{ .name = "List", .module = tui_list },
                .{ .name = "App", .module = tui_app },
                .{ .name = "websocket", .module = websocket_dep.module("websocket") },
            },
        }),
    });
    b.installArtifact(hl);

    const run_hl = b.addRunArtifact(hl);
    if (b.args) |args| run_hl.addArgs(args);
    const run_step = b.step("run", "Run the hl CLI");
    run_step.dependOn(&run_hl.step);

    // ── Static library (for C FFI) ───────────────────────────────────
    const lib = b.addLibrary(.{
        .name = "hyperzig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "websocket", .module = websocket_dep.module("websocket") },
            },
        }),
        .linkage = .static,
    });
    b.installArtifact(lib);
}
