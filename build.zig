const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Dependencies ─────────────────────────────────────────────────
    const websocket_dep = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    // ── Core library module (lib/ + sdk/) ────────────────────────────
    const hyperzig = b.addModule("hyperzig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "websocket", .module = websocket_dep.module("websocket") },
        },
    });

    // ── TUI modules ──────────────────────────────────────────────────
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
    const tui_chart = b.addModule("tui_chart", .{
        .root_source_file = b.path("src/tui/Chart.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "Buffer.zig", .module = tui_buffer },
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

    // ── Terminal module ───────────────────────────────────────────────
    const terminal_mod = b.addModule("trade", .{
        .root_source_file = b.path("src/terminal/trade.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hyperzig", .module = hyperzig },
            .{ .name = "Terminal", .module = tui_terminal },
            .{ .name = "Buffer", .module = tui_buffer },
            .{ .name = "App", .module = tui_app },
            .{ .name = "Chart", .module = tui_chart },

            .{ .name = "websocket", .module = websocket_dep.module("websocket") },
        },
    });

    // Trade stub (just prints "use hl-trade")
    const trade_stub = b.addModule("trade_stub", .{
        .root_source_file = b.path("src/cli/trade_stub.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hyperzig", .module = hyperzig },
        },
    });

    // ── `hl` — CLI + TUI lists, no trading terminal ─────────────
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
                .{ .name = "Chart", .module = tui_chart },
                .{ .name = "trade", .module = trade_stub },
                .{ .name = "websocket", .module = websocket_dep.module("websocket") },
            },
        }),
    });
    b.installArtifact(hl);

    const run_hl = b.addRunArtifact(hl);
    if (b.args) |args| run_hl.addArgs(args);
    b.step("run", "Run the hl CLI").dependOn(&run_hl.step);

    // ── `hl-trade` — full trading terminal ───────────────────────
    const hl_trade = b.addExecutable(.{
        .name = "hl-trade",
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
                .{ .name = "Chart", .module = tui_chart },
                .{ .name = "trade", .module = terminal_mod },
                .{ .name = "websocket", .module = websocket_dep.module("websocket") },
            },
        }),
    });
    b.installArtifact(hl_trade);

    // ── Tests ────────────────────────────────────────────────────────
    const test_step = b.step("test", "Run all tests");

    // Unit tests (lib + sdk)
    const unit_tests = b.addTest(.{ .root_module = hyperzig });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // TUI tests
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tui_layout })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tui_list })).step);

    // Integration tests
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
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);

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
    bench_step.dependOn(&b.addRunArtifact(bench).step);

    // ── E2E tests ────────────────────────────────────────────────────
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
    example_step.dependOn(&b.addRunArtifact(example).step);

    // ── TUI demo ─────────────────────────────────────────────────────
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
    tui_demo_step.dependOn(&b.addRunArtifact(tui_demo).step);

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
