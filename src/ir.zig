//! Core SSA Intermediate Representation and IR-Builder

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Index into a `Function`'s instruction registry.
/// Because every instruction produces exactly one value in SSA form,
/// an `InstIndex` simultaneously identifies an instruction and its result.
pub const InstIndex = enum(u32) {
    /// Sentinel value representing "no instruction" (e.g., a void return).
    none = std.math.maxInt(u32),

    /// Allow implicit integer <-> enum conversions for array indexing.
    _,

    pub fn toInt(self: InstIndex) u32 {
        return @intFromEnum(self);
    }

    pub fn fromInt(i: u32) InstIndex {
        return @enumFromInt(i);
    }
};

/// Index into a `Function`'s block list.
pub const BlockIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn toInt(self: BlockIndex) u32 {
        return @intFromEnum(self);
    }

    pub fn fromInt(i: u32) BlockIndex {
        return @enumFromInt(i);
    }
};

/// The set of opcodes understood by this IR.
pub const Opcode = enum {
    add,
    sub,
    mul,
    icmp_eq,
    br,
    cond_br,
    phi,
    ret,
};

/// A single SSA instruction, represented as a tagged union.
///
/// Every variant carries just enough data for its semantics.
/// Binary arithmetic ops share a common `BinaryOp` payload.
pub const Instruction = union(Opcode) {
    // Arithmetic

    /// Integer addition: result = lhs + rhs
    add: BinaryOp,
    /// Integer subtraction: result = lhs - rhs
    sub: BinaryOp,
    /// Integer multiplication: result = lhs * rhs
    mul: BinaryOp,

    // Comparison

    /// Integer equality comparison: result = (lhs == rhs)
    icmp_eq: BinaryOp,

    // Control flow

    /// Unconditional branch to `target`.
    br: Branch,
    /// Conditional branch: if `cond` is true → `then_target`, else → `else_target`.
    cond_br: CondBranch,

    // SSA

    /// phi-node: merges values arriving from different predecessor blocks.
    /// `incoming_values[i]` comes from `incoming_blocks[i]`.
    phi: Phi,

    // Terminator

    /// Return from the current function, optionally carrying a value.
    ret: Return,

    pub const BinaryOp = struct {
        lhs: InstIndex,
        rhs: InstIndex,
    };

    pub const Branch = struct {
        target: BlockIndex,
    };

    pub const CondBranch = struct {
        cond: InstIndex,
        then_target: BlockIndex,
        else_target: BlockIndex,
    };

    pub const Phi = struct {
        /// Parallel slices — `incoming_values[i]` arrives along the edge
        /// from `incoming_blocks[i]`.  Allocated from the arena.
        incoming_values: []const InstIndex,
        incoming_blocks: []const BlockIndex,
    };

    pub const Return = struct {
        /// The value being returned, or `InstIndex.none` for void returns.
        value: InstIndex,
    };

    // Convenience

    /// Returns the active opcode tag for this instruction.
    pub fn opcode(self: Instruction) Opcode {
        return std.meta.activeTag(self);
    }
};

/// A basic block is a straight-line sequence of instructions with a single
/// entry point and a single exit (the terminator at the end).
pub const BasicBlock = struct {
    /// Ordered list of instruction indices belonging to this block.
    insts: std.ArrayList(InstIndex) = .empty,

    /// Optional human-readable label (e.g., "entry", "loop.header").
    name: ?[]const u8 = null,

    pub fn deinit(self: *BasicBlock, alloc: Allocator) void {
        self.insts.deinit(alloc);
    }
};

/// A function is the top-level unit of compilation.  It owns a flat
/// registry of all instructions and a list of basic blocks that
/// reference those instructions by index.
pub const Function = struct {
    /// The function's name (e.g., "main").
    name: []const u8,

    /// Flat, append-only store of every instruction in this function.
    /// An instruction's position in this array is its `InstIndex`.
    instructions: std.ArrayList(Instruction) = .empty,

    /// Ordered list of basic blocks.  A block's position is its `BlockIndex`.
    blocks: std.ArrayList(BasicBlock) = .empty,

    /// Append a new instruction to the registry and return its index.
    pub fn addInst(self: *Function, alloc: Allocator, inst: Instruction) !InstIndex {
        const idx = InstIndex.fromInt(@intCast(self.instructions.items.len));
        try self.instructions.append(alloc, inst);
        return idx;
    }

    /// Append a new, empty basic block and return its index.
    pub fn addBlock(self: *Function, alloc: Allocator, name: ?[]const u8) !BlockIndex {
        const idx = BlockIndex.fromInt(@intCast(self.blocks.items.len));
        try self.blocks.append(alloc, .{ .name = name });
        return idx;
    }

    /// Retrieve an instruction by its index.
    pub fn getInst(self: *const Function, idx: InstIndex) Instruction {
        return self.instructions.items[@intFromEnum(idx)];
    }

    /// Retrieve a basic block by its index.
    pub fn getBlock(self: *Function, idx: BlockIndex) *BasicBlock {
        return &self.blocks.items[@intFromEnum(idx)];
    }

    pub fn deinit(self: *Function, alloc: Allocator) void {
        for (self.blocks.items) |*blk| {
            blk.deinit(alloc);
        }
        self.blocks.deinit(alloc);
        self.instructions.deinit(alloc);
    }
};

/// Ergonomic builder for constructing SSA IR.
///
/// Usage:
/// ```
///   var builder = IRBuilder.init(arena_alloc, &func);
///   const entry = try builder.appendBlock("entry");
///   builder.setInsertPoint(entry);
///   const v0 = try builder.buildAdd(arg0, arg1);
///   _ = try builder.buildRet(v0);
/// ```
pub const IRBuilder = struct {
    /// The function currently being constructed.
    function: *Function,

    /// Arena allocator — all IR memory lives here for the duration
    /// of the module's compilation.
    alloc: Allocator,

    /// The block into which new instructions are appended.
    /// `null` means no insert point has been set yet.
    current_block: ?BlockIndex = null,

    /// Create a new builder targeting `func`, allocating from `alloc`.
    pub fn init(alloc: Allocator, function: *Function) IRBuilder {
        return .{
            .function = function,
            .alloc = alloc,
        };
    }

    /// Set the block where subsequent instructions will be appended.
    pub fn setInsertPoint(self: *IRBuilder, block: BlockIndex) void {
        self.current_block = block;
    }

    /// Return the current insert block, or `null` if none is set.
    pub fn getInsertBlock(self: *const IRBuilder) ?BlockIndex {
        return self.current_block;
    }

    /// Append a new basic block to the function and return its index.
    /// Does *not* change the current insert point.
    pub fn appendBlock(self: *IRBuilder, name: ?[]const u8) !BlockIndex {
        return self.function.addBlock(self.alloc, name);
    }

    /// Emit a generic instruction: register it in the function, append its
    /// index to the current block, and return the `InstIndex` (= SSA value).
    fn emit(self: *IRBuilder, inst: Instruction) !InstIndex {
        const blk_idx = self.current_block orelse
            return error.NoInsertPoint;

        // 1. Append instruction to the flat registry.
        const idx = try self.function.addInst(self.alloc, inst);

        // 2. Append its index to the current basic block.
        const blk = self.function.getBlock(blk_idx);
        try blk.insts.append(self.alloc, idx);

        return idx;
    }

    /// Build an integer addition: `result = lhs + rhs`.
    pub fn buildAdd(self: *IRBuilder, lhs: InstIndex, rhs: InstIndex) !InstIndex {
        return self.emit(.{ .add = .{ .lhs = lhs, .rhs = rhs } });
    }

    /// Build an integer subtraction: `result = lhs - rhs`.
    pub fn buildSub(self: *IRBuilder, lhs: InstIndex, rhs: InstIndex) !InstIndex {
        return self.emit(.{ .sub = .{ .lhs = lhs, .rhs = rhs } });
    }

    /// Build an integer multiplication: `result = lhs * rhs`.
    pub fn buildMul(self: *IRBuilder, lhs: InstIndex, rhs: InstIndex) !InstIndex {
        return self.emit(.{ .mul = .{ .lhs = lhs, .rhs = rhs } });
    }

    /// Build an integer equality comparison: `result = (lhs == rhs)`.
    pub fn buildICmpEq(self: *IRBuilder, lhs: InstIndex, rhs: InstIndex) !InstIndex {
        return self.emit(.{ .icmp_eq = .{ .lhs = lhs, .rhs = rhs } });
    }

    /// Build an unconditional branch to `target`.
    pub fn buildBr(self: *IRBuilder, target: BlockIndex) !InstIndex {
        return self.emit(.{ .br = .{ .target = target } });
    }

    /// Build a conditional branch:
    ///   if `cond` → `then_target`, else → `else_target`.
    pub fn buildCondBr(
        self: *IRBuilder,
        cond: InstIndex,
        then_target: BlockIndex,
        else_target: BlockIndex,
    ) !InstIndex {
        return self.emit(.{ .cond_br = .{
            .cond = cond,
            .then_target = then_target,
            .else_target = else_target,
        } });
    }

    /// Build a phi-node merging `incoming_values` from `incoming_blocks`.
    ///
    /// Both slices must have the same length.  The slices are expected to
    /// be arena-allocated (or otherwise outlive the function).
    pub fn buildPhi(
        self: *IRBuilder,
        incoming_values: []const InstIndex,
        incoming_blocks: []const BlockIndex,
    ) !InstIndex {
        std.debug.assert(incoming_values.len == incoming_blocks.len);
        return self.emit(.{ .phi = .{
            .incoming_values = incoming_values,
            .incoming_blocks = incoming_blocks,
        } });
    }

    /// Build a return instruction.
    ///   - `value`:  the SSA value to return, or `null` for a void return.
    pub fn buildRet(self: *IRBuilder, value: ?InstIndex) !InstIndex {
        return self.emit(.{ .ret = .{
            .value = value orelse InstIndex.none,
        } });
    }
};

test "IRBuilder — build simple add+ret" {
    // We use a standard testing allocator here; in production this would
    // be an ArenaAllocator wrapping a page allocator.
    const alloc = std.testing.allocator;

    // Set up a function
    var func: Function = .{ .name = "simple_add" };
    defer func.deinit(alloc);

    var builder = IRBuilder.init(alloc, &func);

    // Create the entry block and set it as the insertion point
    const entry = try builder.appendBlock("entry");
    builder.setInsertPoint(entry);

    // In a real compiler, function arguments would be represented as
    // dedicated `arg` instructions.  Here we simulate two arguments
    // by emitting two dummy adds (both operands are self-referential,
    // which is nonsensical but sufficient for a structural test).
    const arg0 = try builder.buildAdd(InstIndex.fromInt(0), InstIndex.fromInt(0));
    const arg1 = try builder.buildAdd(InstIndex.fromInt(1), InstIndex.fromInt(1));

    // Emit: %2 = add %0, %1
    const sum = try builder.buildAdd(arg0, arg1);

    // Emit: ret %2
    const ret = try builder.buildRet(sum);

    // The function should contain exactly 4 instructions.
    try std.testing.expectEqual(@as(usize, 4), func.instructions.items.len);

    // The function should contain exactly 1 block.
    try std.testing.expectEqual(@as(usize, 1), func.blocks.items.len);

    // The entry block should reference all 4 instructions.
    const entry_blk = func.getBlock(entry);
    try std.testing.expectEqual(@as(usize, 4), entry_blk.insts.items.len);

    // Instruction 2 should be an add of %0 and %1.
    const add_inst = func.getInst(sum);
    try std.testing.expectEqual(Opcode.add, add_inst.opcode());
    try std.testing.expectEqual(arg0, add_inst.add.lhs);
    try std.testing.expectEqual(arg1, add_inst.add.rhs);

    // Instruction 3 should be a ret of %2.
    const ret_inst = func.getInst(ret);
    try std.testing.expectEqual(Opcode.ret, ret_inst.opcode());
    try std.testing.expectEqual(sum, ret_inst.ret.value);

    // The entry block's name should be "entry".
    try std.testing.expectEqualStrings("entry", entry_blk.name.?);
}

test "IRBuilder — conditional branch with phi" {
    const alloc = std.testing.allocator;

    var func: Function = .{ .name = "cond_example" };
    defer func.deinit(alloc);

    var builder = IRBuilder.init(alloc, &func);

    // Create three blocks: entry, then, merge.
    const entry = try builder.appendBlock("entry");
    const then_blk = try builder.appendBlock("then");
    const merge_blk = try builder.appendBlock("merge");

    // entry block
    builder.setInsertPoint(entry);
    // Simulate a condition value (dummy self-referential add).
    const cond = try builder.buildAdd(InstIndex.fromInt(0), InstIndex.fromInt(0));
    _ = try builder.buildCondBr(cond, then_blk, merge_blk);

    // then block
    builder.setInsertPoint(then_blk);
    const val_then = try builder.buildAdd(InstIndex.fromInt(0), InstIndex.fromInt(0));
    _ = try builder.buildBr(merge_blk);

    // merge block (with a phi)
    builder.setInsertPoint(merge_blk);
    const phi_val = try builder.buildPhi(
        &[_]InstIndex{ val_then, cond },
        &[_]BlockIndex{ then_blk, entry },
    );
    _ = try builder.buildRet(phi_val);

    try std.testing.expectEqual(@as(usize, 3), func.blocks.items.len);

    // Check the phi node.
    const phi_inst = func.getInst(phi_val);
    try std.testing.expectEqual(Opcode.phi, phi_inst.opcode());
    try std.testing.expectEqual(@as(usize, 2), phi_inst.phi.incoming_values.len);
    try std.testing.expectEqual(val_then, phi_inst.phi.incoming_values[0]);
    try std.testing.expectEqual(entry, phi_inst.phi.incoming_blocks[1]);
}

test "IRBuilder — error on emit without insert point" {
    const alloc = std.testing.allocator;

    var func: Function = .{ .name = "no_block" };
    defer func.deinit(alloc);

    var builder = IRBuilder.init(alloc, &func);

    // Attempting to emit without setting an insert point should fail.
    const result = builder.buildAdd(InstIndex.fromInt(0), InstIndex.fromInt(1));
    try std.testing.expectError(error.NoInsertPoint, result);
}
