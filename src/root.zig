//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

/// Core SSA Intermediate Representation and builder API.
pub const ir = @import("ir.zig");

/// Generic backend framework (MachineFunction, TargetMachine vtable, etc.).
pub const backend = @import("backend.zig");

/// x86_64 target definitions and backend implementation.
pub const x86_64 = @import("x86_64.zig");

/// Phi elimination pass.
pub const phi_elimination = @import("phi_elimination.zig");

pub fn bufferedPrint() !void {
    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try stdout.flush(); // Don't forget to flush!
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
