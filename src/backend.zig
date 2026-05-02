//! Generic Backend Framework
//!
//! Provides target-agnostic data structures for the Machine IR layer
//! and a `TargetMachine` vtable interface for target polymorphism.
//! All machine-level types are parameterised on the target's `MachineInstr`
//! type so that the same framework can be reused for x86_64, ARM64, RISC-V, etc.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");

/// A basic block in the Machine IR.  Holds an ordered list of target-specific
/// machine instructions and optional metadata (label, successor edges).
pub fn MachineBasicBlock(comptime Instr: type) type {
    return struct {
        const Self = @This();

        /// Ordered machine instructions in this block.
        insts: std.ArrayList(Instr) = .empty,

        /// Human-readable label (e.g. ".LBB0_entry").
        label: ?[]const u8 = null,

        /// Indices of successor MBBs (for future liveness / CFG analysis).
        successors: std.ArrayList(u32) = .empty,

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.insts.deinit(alloc);
            self.successors.deinit(alloc);
        }
    };
}

/// A function in the Machine IR.  Owns a list of `MachineBasicBlock`s and a
/// monotonically increasing virtual-register counter.
pub fn MachineFunction(comptime Instr: type) type {
    return struct {
        const Self = @This();
        pub const MBB = MachineBasicBlock(Instr);

        /// The function's name.
        name: []const u8,

        /// Ordered list of machine basic blocks.
        blocks: std.ArrayList(MBB) = .empty,

        /// Next virtual register number to hand out.
        next_vreg: u32 = 0,

        /// Allocate a fresh virtual register number.
        pub fn nextVReg(self: *Self) u32 {
            const vr = self.next_vreg;
            self.next_vreg += 1;
            return vr;
        }

        /// Append a new, empty machine basic block and return its index.
        pub fn addBlock(self: *Self, alloc: Allocator, label: ?[]const u8) !u32 {
            const idx: u32 = @intCast(self.blocks.items.len);
            try self.blocks.append(alloc, .{ .label = label });
            return idx;
        }

        /// Get a mutable pointer to the block at `idx`.
        pub fn getBlock(self: *Self, idx: u32) *MBB {
            return &self.blocks.items[idx];
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            for (self.blocks.items) |*blk| {
                blk.deinit(alloc);
            }
            self.blocks.deinit(alloc);
        }
    };
}

/// A target-agnostic interface for driving the backend pipeline.
///
/// Each concrete target (e.g. `X86_64Target`) provides its own `ctx` pointer
/// and three function-pointer hooks.  The caller uses the convenience methods
/// (`lowerIR`, `allocateRegisters`, `emitAssembly`) without knowing which
/// target is behind the vtable.
///
/// The `MachineFunction` is passed as `*anyopaque` across the vtable boundary
/// because its concrete type depends on the target's `MachineInstr`.
pub const TargetMachine = struct {
    /// Opaque pointer to the concrete target instance.
    ctx: *anyopaque,

    /// Instruction Selection: lower SSA IR into a target-specific MachineFunction.
    /// Returns an arena-allocated MachineFunction as an opaque pointer.
    lower_ir_fn: *const fn (ctx: *anyopaque, alloc: Allocator, func: *const ir.Function) anyerror!*anyopaque,

    /// Register Allocation: rewrite virtual registers to physical registers.
    reg_alloc_fn: *const fn (ctx: *anyopaque, alloc: Allocator, mf: *anyopaque) anyerror!void,

    /// Assembly Emission: serialise the MachineFunction to text assembly.
    emit_asm_fn: *const fn (ctx: *anyopaque, mf: *anyopaque, writer: std.io.AnyWriter) anyerror!void,

    /// Deallocate a MachineFunction produced by `lowerIR`.
    deinit_mf_fn: *const fn (ctx: *anyopaque, alloc: Allocator, mf: *anyopaque) void,

    pub fn lowerIR(self: TargetMachine, alloc: Allocator, func: *const ir.Function) !*anyopaque {
        return self.lower_ir_fn(self.ctx, alloc, func);
    }

    pub fn allocateRegisters(self: TargetMachine, alloc: Allocator, mf: *anyopaque) !void {
        return self.reg_alloc_fn(self.ctx, alloc, mf);
    }

    pub fn emitAssembly(self: TargetMachine, mf: *anyopaque, writer: std.io.AnyWriter) !void {
        return self.emit_asm_fn(self.ctx, mf, writer);
    }

    pub fn deinitMachineFunction(self: TargetMachine, alloc: Allocator, mf: *anyopaque) void {
        self.deinit_mf_fn(self.ctx, alloc, mf);
    }
};
