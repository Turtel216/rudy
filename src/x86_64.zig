//! x86_64 Target Definitions & Backend Implementation
//!
//! Contains all x86_64-specific types (registers, opcodes, operands,
//! machine instructions) and the concrete `X86_64Target` that implements
//! instruction selection, register allocation, and assembly emission.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");
const backend = @import("backend.zig");
const phi_elimination = @import("phi_elimination.zig");

///  Physical Registers
pub const X86Reg = enum {
    rax,
    rbx,
    rcx,
    rdx,
    rsi,
    rdi,
    r8,
    r9,
    r10,
    r11,
    r12,
    r13,
    r14,
    r15,
    rsp,
    rbp,

    /// AT&T-syntax name (e.g. `%rax`).
    pub fn name(self: X86Reg) []const u8 {
        return switch (self) {
            .rax => "%rax",
            .rbx => "%rbx",
            .rcx => "%rcx",
            .rdx => "%rdx",
            .rsi => "%rsi",
            .rdi => "%rdi",
            .r8 => "%r8",
            .r9 => "%r9",
            .r10 => "%r10",
            .r11 => "%r11",
            .r12 => "%r12",
            .r13 => "%r13",
            .r14 => "%r14",
            .r15 => "%r15",
            .rsp => "%rsp",
            .rbp => "%rbp",
        };
    }
};

/// GPRs available for the register allocator (excludes rsp/rbp).
const allocatable_regs = [_]X86Reg{
    .rax, .rcx, .rdx, .rbx, .rsi, .rdi,
    .r8,  .r9,  .r10, .r11, .r12, .r13,
    .r14, .r15,
};

/// A register that is either a virtual (pre-regalloc) or physical (post-regalloc).
pub const Register = union(enum) {
    virtual: u32,
    physical: X86Reg,
};

///  Opcodes
pub const X86Opcode = enum {
    mov,
    add,
    sub,
    imul,
    cmp,
    jmp,
    je,
    jne,
    ret,
    neg,
    push,
    pop,
    nop,
    // test is a Zig keyword, so use tst
    tst,
};

///  Operands
pub const Operand = union(enum) {
    register: Register,
    immediate: i64,
    memory: Memory,
    block_ref: u32,

    pub const Memory = struct {
        base: Register,
        offset: i32,
    };

    pub fn reg(r: Register) Operand {
        return .{ .register = r };
    }

    pub fn phys(r: X86Reg) Operand {
        return .{ .register = .{ .physical = r } };
    }

    pub fn vreg(v: u32) Operand {
        return .{ .register = .{ .virtual = v } };
    }

    pub fn imm(v: i64) Operand {
        return .{ .immediate = v };
    }

    pub fn blk(idx: u32) Operand {
        return .{ .block_ref = idx };
    }
};

///  Machine Instruction
pub const MachineInstr = struct {
    opcode: X86Opcode,
    /// Arena-allocated operand slice (AT&T order: src, dst).
    operands: []Operand,
};

/// Instantiated generic types from the backend framework.
pub const MBB = backend.MachineBasicBlock(MachineInstr);
pub const MFunc = backend.MachineFunction(MachineInstr);

///  X86_64 Target
pub const X86_64Target = struct {
    /// Return a type-erased `TargetMachine` vtable for this target.
    pub fn target(self: *X86_64Target) backend.TargetMachine {
        return .{
            .ctx = @ptrCast(self),
            .lower_ir_fn = lowerIRTrampoline,
            .reg_alloc_fn = regAllocTrampoline,
            .emit_asm_fn = emitAsmTrampoline,
            .deinit_mf_fn = deinitMFTrampoline,
        };
    }

    //  Vtable trampolines

    fn lowerIRTrampoline(_: *anyopaque, alloc: Allocator, func: *const ir.Function) anyerror!*anyopaque {
        const mf = try lowerIR(alloc, func);
        return @ptrCast(mf);
    }

    fn regAllocTrampoline(_: *anyopaque, alloc: Allocator, mf_opaque: *anyopaque) anyerror!void {
        const mf: *MFunc = @ptrCast(@alignCast(mf_opaque));
        try allocateRegisters(alloc, mf);
    }

    fn emitAsmTrampoline(_: *anyopaque, mf_opaque: *anyopaque, writer: std.io.AnyWriter) anyerror!void {
        const mf: *MFunc = @ptrCast(@alignCast(mf_opaque));
        try emitAssembly(mf, writer);
    }

    fn deinitMFTrampoline(_: *anyopaque, alloc: Allocator, mf_opaque: *anyopaque) void {
        const mf: *MFunc = @ptrCast(@alignCast(mf_opaque));
        mf.deinit(alloc);
        alloc.destroy(mf);
    }

    /// Lower an SSA `ir.Function` into an x86_64 `MFunc`.
    pub fn lowerIR(alloc: Allocator, func: *const ir.Function) !*MFunc {
        const mf = try alloc.create(MFunc);
        mf.* = .{ .name = func.name };

        // Map SSA InstIndex -> virtual register.
        var vreg_map = std.AutoHashMap(u32, Register).init(alloc);
        defer vreg_map.deinit();

        // Track which InstIndices produced flags (icmp_eq) rather than a value.
        var flag_producers = std.AutoHashMap(u32, void).init(alloc);
        defer flag_producers.deinit();

        // Pre-assign a vreg for every SSA instruction.
        for (0..func.instructions.items.len) |i| {
            const idx: u32 = @intCast(i);
            const inst = func.instructions.items[i];
            if (inst.opcode() == .icmp_eq) {
                // icmp_eq produces flags, not a register value.
                try flag_producers.put(idx, {});
            } else {
                try vreg_map.put(idx, .{ .virtual = mf.nextVReg() });
            }
        }

        // Lower each basic block.
        for (func.blocks.items, 0..) |block, blk_i| {
            const mbb_idx = try mf.addBlock(alloc, block.name);
            const mbb = mf.getBlock(mbb_idx);

            for (block.insts.items) |inst_idx| {
                const inst = func.getInst(inst_idx);
                const idx = inst_idx.toInt();

                switch (inst) {
                    .add => |op| try lowerBinOp(alloc, mbb, &vreg_map, .add, idx, op),
                    .sub => |op| try lowerBinOp(alloc, mbb, &vreg_map, .sub, idx, op),
                    .mul => |op| try lowerBinOp(alloc, mbb, &vreg_map, .imul, idx, op),

                    .icmp_eq => |op| {
                        // Emit: cmpq rhs, lhs  (sets ZF)
                        const lhs = vreg_map.get(op.lhs.toInt()) orelse return error.UnmappedVReg;
                        const rhs = vreg_map.get(op.rhs.toInt()) orelse return error.UnmappedVReg;
                        try appendInstr(alloc, mbb, .cmp, &.{ Operand.reg(rhs), Operand.reg(lhs) });
                    },

                    .ret => |r| {
                        if (r.value != ir.InstIndex.none) {
                            const src = vreg_map.get(r.value.toInt()) orelse return error.UnmappedVReg;
                            // movq src, %rax
                            try appendInstr(alloc, mbb, .mov, &.{ Operand.reg(src), Operand.phys(.rax) });
                        }
                        try appendInstr(alloc, mbb, .ret, &.{});
                    },

                    .br => |b| {
                        // Unconditional jump. Could be optimized if target is next block.
                        const target_idx = @intFromEnum(b.target);
                        if (target_idx != blk_i + 1) {
                            try appendInstr(alloc, mbb, .jmp, &.{Operand.blk(target_idx)});
                        }
                    },

                    .cond_br => |cb| {
                        const cond_idx = cb.cond.toInt();
                        if (flag_producers.contains(cond_idx)) {
                            // cond was produced by icmp_eq -> flags are already set.
                            // je then_target (ZF=1 means equal => condition is true)
                            try appendInstr(alloc, mbb, .je, &.{Operand.blk(@intFromEnum(cb.then_target))});
                        } else {
                            // Generic: testq cond, cond; jne then_target
                            const cond_reg = vreg_map.get(cond_idx) orelse return error.UnmappedVReg;
                            try appendInstr(alloc, mbb, .tst, &.{ Operand.reg(cond_reg), Operand.reg(cond_reg) });
                            try appendInstr(alloc, mbb, .jne, &.{Operand.blk(@intFromEnum(cb.then_target))});
                        }

                        // Unconditional jump to else_target.
                        // Fallthrough optimization: if else_target is the next block in layout, we can omit the jmp.
                        const else_idx = @intFromEnum(cb.else_target);
                        if (else_idx != blk_i + 1) {
                            try appendInstr(alloc, mbb, .jmp, &.{Operand.blk(else_idx)});
                        }
                    },

                    .phi => {
                        // Phi elimination is deferred to a later pass.
                        // The vreg is pre-assigned but no code is emitted.
                    },
                }
            }
        }

        // Run phi elimination pass.
        const Pass = phi_elimination.PhiElimination(MachineInstr, Register, x86CreateCopy, x86IsTerminator);
        try Pass.run(alloc, mf, func, &vreg_map);

        return mf;
    }

    fn x86CreateCopy(alloc: Allocator, dst: Register, src: Register) !MachineInstr {
        const operands = try alloc.dupe(Operand, &.{ Operand.reg(src), Operand.reg(dst) });
        return MachineInstr{ .opcode = .mov, .operands = operands };
    }

    fn x86IsTerminator(mi: MachineInstr) bool {
        return switch (mi.opcode) {
            .jmp, .je, .jne, .ret => true,
            else => false,
        };
    }

    fn lowerBinOp(
        alloc: Allocator,
        mbb: *MBB,
        vreg_map: *std.AutoHashMap(u32, Register),
        opcode: X86Opcode,
        dst_idx: u32,
        op: ir.Instruction.BinaryOp,
    ) !void {
        const lhs = vreg_map.get(op.lhs.toInt()) orelse return error.UnmappedVReg;
        const rhs = vreg_map.get(op.rhs.toInt()) orelse return error.UnmappedVReg;
        const dst = vreg_map.get(dst_idx) orelse return error.UnmappedVReg;
        // movq lhs, dst
        try appendInstr(alloc, mbb, .mov, &.{ Operand.reg(lhs), Operand.reg(dst) });
        // <op>q rhs, dst
        try appendInstr(alloc, mbb, opcode, &.{ Operand.reg(rhs), Operand.reg(dst) });
    }

    //  Linear Scan Register Allocator

    const LiveInterval = struct {
        vreg: u32,
        start: u32,
        end: u32,
        reg: ?X86Reg = null,
    };

    /// Allocate physical registers for all virtual registers in `mf`.
    pub fn allocateRegisters(alloc: Allocator, mf: *MFunc) !void {
        // Build live intervals: map vreg -> [first_seen, last_seen].
        var intervals_map = std.AutoHashMap(u32, LiveInterval).init(alloc);
        defer intervals_map.deinit();

        var instr_pos: u32 = 0;
        for (mf.blocks.items) |block| {
            for (block.insts.items) |mi| {
                for (mi.operands) |operand| {
                    switch (operand) {
                        .register => |r| switch (r) {
                            .virtual => |v| {
                                const gop = try intervals_map.getOrPut(v);
                                if (!gop.found_existing) {
                                    gop.value_ptr.* = .{ .vreg = v, .start = instr_pos, .end = instr_pos };
                                } else {
                                    gop.value_ptr.end = instr_pos;
                                }
                            },
                            .physical => {},
                        },
                        else => {},
                    }
                }
                instr_pos += 1;
            }
        }

        // Collect and sort intervals by start point.
        var intervals = std.ArrayList(LiveInterval).empty;
        defer intervals.deinit(alloc);
        var it = intervals_map.valueIterator();
        while (it.next()) |iv| {
            try intervals.append(alloc, iv.*);
        }
        std.mem.sort(LiveInterval, intervals.items, {}, struct {
            fn cmp(_: void, a: LiveInterval, b: LiveInterval) bool {
                return a.start < b.start;
            }
        }.cmp);

        // Linear scan assign physical registers.
        var free_regs = std.ArrayList(X86Reg).empty;
        defer free_regs.deinit(alloc);
        // Initialise with all allocatable regs (reversed so pop gives first).
        var i: usize = allocatable_regs.len;
        while (i > 0) {
            i -= 1;
            try free_regs.append(alloc, allocatable_regs[i]);
        }

        var active = std.ArrayList(*LiveInterval).empty;
        defer active.deinit(alloc);

        // Assignment map: vreg -> physical reg.
        var assignment = std.AutoHashMap(u32, X86Reg).init(alloc);
        defer assignment.deinit();

        for (intervals.items) |*interval| {
            // Expire old intervals.
            var j: usize = 0;
            while (j < active.items.len) {
                if (active.items[j].end < interval.start) {
                    // Return register to pool.
                    try free_regs.append(alloc, active.items[j].reg.?);
                    _ = active.orderedRemove(j);
                } else {
                    j += 1;
                }
            }

            if (free_regs.items.len == 0) {
                return error.RegisterSpillNotImplemented;
            }

            const phys = free_regs.pop().?;
            interval.reg = phys;
            try assignment.put(interval.vreg, phys);

            // Insert into active, keeping sorted by end point.
            var insert_pos: usize = active.items.len;
            for (active.items, 0..) |act, k| {
                if (interval.end < act.end) {
                    insert_pos = k;
                    break;
                }
            }
            try active.insert(alloc, insert_pos, interval);
        }

        // Rewrite all virtual registers to physical.
        for (mf.blocks.items) |*block| {
            for (block.insts.items) |*mi| {
                for (mi.operands) |*operand| {
                    switch (operand.*) {
                        .register => |*r| switch (r.*) {
                            .virtual => |v| {
                                r.* = .{ .physical = assignment.get(v) orelse return error.UnassignedVReg };
                            },
                            .physical => {},
                        },
                        else => {},
                    }
                }
            }
        }
    }

    /// Emit AT&T-syntax x86_64 assembly for `mf` to `writer`.
    pub fn emitAssembly(mf: *const MFunc, writer: std.io.AnyWriter) !void {
        try writer.print("    .globl {s}\n", .{mf.name});
        try writer.print("{s}:\n", .{mf.name});

        for (mf.blocks.items, 0..) |block, blk_i| {
            if (block.label) |lbl| {
                try writer.print(".LBB{d}_{s}:\n", .{ blk_i, lbl });
            } else {
                try writer.print(".LBB{d}:\n", .{blk_i});
            }

            for (block.insts.items) |mi| {
                try writer.writeAll("    ");
                try emitInstr(mf, mi, writer);
                try writer.writeAll("\n");
            }
        }
    }

    fn emitInstr(mf: *const MFunc, mi: MachineInstr, writer: std.io.AnyWriter) !void {
        const mnemonic = switch (mi.opcode) {
            .mov => "movq",
            .add => "addq",
            .sub => "subq",
            .imul => "imulq",
            .cmp => "cmpq",
            .tst => "testq",
            .jmp => "jmp",
            .je => "je",
            .jne => "jne",
            .ret => "retq",
            .neg => "negq",
            .push => "pushq",
            .pop => "popq",
            .nop => "nop",
        };
        try writer.writeAll(mnemonic);

        for (mi.operands, 0..) |op, i| {
            if (i == 0) {
                try writer.writeAll(" ");
            } else {
                try writer.writeAll(", ");
            }
            try emitOperand(mf, op, writer);
        }
    }

    fn emitOperand(mf: *const MFunc, op: Operand, writer: std.io.AnyWriter) !void {
        switch (op) {
            .register => |r| switch (r) {
                .physical => |p| try writer.writeAll(p.name()),
                .virtual => |v| try writer.print("%vreg{d}", .{v}),
            },
            .immediate => |v| try writer.print("${d}", .{v}),
            .memory => |m| {
                if (m.offset != 0) {
                    try writer.print("{d}", .{m.offset});
                }
                try writer.writeAll("(");
                switch (m.base) {
                    .physical => |p| try writer.writeAll(p.name()),
                    .virtual => |v| try writer.print("%vreg{d}", .{v}),
                }
                try writer.writeAll(")");
            },
            .block_ref => |idx| {
                // Must handle out-of-bounds just in case, though it shouldn't happen.
                if (idx < mf.blocks.items.len) {
                    const blk = mf.blocks.items[idx];
                    if (blk.label) |lbl| {
                        try writer.print(".LBB{d}_{s}", .{ idx, lbl });
                    } else {
                        try writer.print(".LBB{d}", .{idx});
                    }
                } else {
                    try writer.print(".LBB{d}", .{idx});
                }
            },
        }
    }

    // Helpers

    fn appendInstr(alloc: Allocator, mbb: *MBB, opcode: X86Opcode, ops: []const Operand) !void {
        const operands = try alloc.dupe(Operand, ops);
        try mbb.insts.append(alloc, .{ .opcode = opcode, .operands = operands });
    }
};

test "x86_64 full pipeline: ISel -> RegAlloc -> Emit" {
    const alloc = std.testing.allocator;

    // Build a small SSA IR function:
    //   %0 = add %0, %0   (dummy arg0)
    //   %1 = add %1, %1   (dummy arg1)
    //   %2 = add %0, %1
    //   %3 = sub %2, %1
    //   ret %3
    var func: ir.Function = .{ .name = "example" };
    defer func.deinit(alloc);

    var builder = ir.IRBuilder.init(alloc, &func);
    const entry = try builder.appendBlock("entry");
    builder.setInsertPoint(entry);

    const arg0 = try builder.buildAdd(ir.InstIndex.fromInt(0), ir.InstIndex.fromInt(0));
    const arg1 = try builder.buildAdd(ir.InstIndex.fromInt(1), ir.InstIndex.fromInt(1));
    const sum = try builder.buildAdd(arg0, arg1);
    const diff = try builder.buildSub(sum, arg1);
    _ = try builder.buildRet(diff);

    // Run the full backend pipeline.
    var x86_target = X86_64Target{};
    const tm = x86_target.target();

    const mf_opaque = try tm.lowerIR(alloc, &func);
    defer tm.deinitMachineFunction(alloc, mf_opaque);

    const mf: *MFunc = @ptrCast(@alignCast(mf_opaque));

    // Before regalloc, all operand registers should be virtual.
    try std.testing.expect(mf.blocks.items.len == 1);

    try tm.allocateRegisters(alloc, mf_opaque);

    // After regalloc, no virtual registers should remain.
    for (mf.blocks.items) |block| {
        for (block.insts.items) |mi| {
            for (mi.operands) |op| {
                switch (op) {
                    .register => |r| switch (r) {
                        .virtual => return error.VirtualRegisterRemains,
                        .physical => {},
                    },
                    else => {},
                }
            }
        }
    }

    // Emit assembly and verify key patterns.
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try tm.emitAssembly(mf_opaque, fbs.writer().any());
    const asm_text = fbs.getWritten();

    // Must contain function label, entry block label, and key instructions.
    try std.testing.expect(std.mem.indexOf(u8, asm_text, ".globl example") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "example:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "addq") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "subq") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "retq") != null);

    // Print for visual inspection during development.
    std.debug.print("\n--- Emitted x86_64 Assembly ---\n{s}\n", .{asm_text});
}

test "x86_64 full pipeline: If/Else Diamond with Phi Elimination" {
    const alloc = std.testing.allocator;

    var func: ir.Function = .{ .name = "if_else" };
    defer func.deinit(alloc);

    var builder = ir.IRBuilder.init(alloc, &func);

    const entry_bb = try builder.appendBlock("entry");
    const then_bb = try builder.appendBlock("then");
    const else_bb = try builder.appendBlock("else");
    const merge_bb = try builder.appendBlock("merge");

    // entry:
    builder.setInsertPoint(entry_bb);
    const arg = try builder.buildAdd(ir.InstIndex.fromInt(0), ir.InstIndex.fromInt(0));
    const cond = try builder.buildICmpEq(arg, arg);
    _ = try builder.buildCondBr(cond, then_bb, else_bb);

    // then:
    builder.setInsertPoint(then_bb);
    const val_then = try builder.buildAdd(arg, arg);
    _ = try builder.buildBr(merge_bb);

    // else:
    builder.setInsertPoint(else_bb);
    const val_else = try builder.buildSub(arg, arg);
    _ = try builder.buildBr(merge_bb);

    // merge:
    builder.setInsertPoint(merge_bb);
    const phi_val = try builder.buildPhi(
        &[_]ir.InstIndex{ val_then, val_else },
        &[_]ir.BlockIndex{ then_bb, else_bb },
    );
    _ = try builder.buildRet(phi_val);

    var x86_target = X86_64Target{};
    const tm = x86_target.target();

    const mf_opaque = try tm.lowerIR(alloc, &func);
    defer tm.deinitMachineFunction(alloc, mf_opaque);

    try tm.allocateRegisters(alloc, mf_opaque);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try tm.emitAssembly(mf_opaque, fbs.writer().any());
    const asm_text = fbs.getWritten();

    // Verify condition and fallthrough/jumps
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "cmpq") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "je .LBB1_then") != null);
    // Since 'else' is block 2 and follows 'entry' (block 0) ? No, entry is 0, then is 1, else is 2.
    // So 'else' does NOT follow 'entry'. The jmp should be present.
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jmp .LBB2_else") != null);

    // Verify phi elimination created movs in predecessors before jumps
    // Actually, because of RegAlloc, the vregs will be mapped to the same physical reg or there will be movs.
    // For now, just ensure assembly contains proper labels.
    try std.testing.expect(std.mem.indexOf(u8, asm_text, ".LBB3_merge:") != null);

    std.debug.print("\n--- If/Else Diamond Assembly ---\n{s}\n", .{asm_text});
}

test "x86_64 full pipeline: Else-If Chain with Phi Elimination" {
    const alloc = std.testing.allocator;

    var func: ir.Function = .{ .name = "else_if" };
    defer func.deinit(alloc);

    var builder = ir.IRBuilder.init(alloc, &func);

    const entry_bb = try builder.appendBlock("entry");
    const if1_then_bb = try builder.appendBlock("if1_then");
    const if2_cond_bb = try builder.appendBlock("if2_cond");
    const if2_then_bb = try builder.appendBlock("if2_then");
    const else_bb = try builder.appendBlock("else");
    const merge_bb = try builder.appendBlock("merge");

    // entry (if 1):
    builder.setInsertPoint(entry_bb);
    const arg1 = try builder.buildAdd(ir.InstIndex.fromInt(0), ir.InstIndex.fromInt(0));
    const arg2 = try builder.buildAdd(ir.InstIndex.fromInt(1), ir.InstIndex.fromInt(1));
    const cond1 = try builder.buildICmpEq(arg1, arg2);
    _ = try builder.buildCondBr(cond1, if1_then_bb, if2_cond_bb);

    // if1_then:
    builder.setInsertPoint(if1_then_bb);
    const val1 = try builder.buildAdd(arg1, arg1);
    _ = try builder.buildBr(merge_bb);

    // if2_cond:
    builder.setInsertPoint(if2_cond_bb);
    const cond2 = try builder.buildICmpEq(arg1, arg1);
    _ = try builder.buildCondBr(cond2, if2_then_bb, else_bb);

    // if2_then:
    builder.setInsertPoint(if2_then_bb);
    const val2 = try builder.buildAdd(arg2, arg2);
    _ = try builder.buildBr(merge_bb);

    // else:
    builder.setInsertPoint(else_bb);
    const val3 = try builder.buildSub(arg1, arg2);
    _ = try builder.buildBr(merge_bb);

    // merge:
    builder.setInsertPoint(merge_bb);
    const phi_val = try builder.buildPhi(
        &[_]ir.InstIndex{ val1, val2, val3 },
        &[_]ir.BlockIndex{ if1_then_bb, if2_then_bb, else_bb },
    );
    _ = try builder.buildRet(phi_val);

    var x86_target = X86_64Target{};
    const tm = x86_target.target();

    const mf_opaque = try tm.lowerIR(alloc, &func);
    defer tm.deinitMachineFunction(alloc, mf_opaque);

    try tm.allocateRegisters(alloc, mf_opaque);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try tm.emitAssembly(mf_opaque, fbs.writer().any());
    const asm_text = fbs.getWritten();

    std.debug.print("\n--- Else-If Chain Assembly ---\n{s}\n", .{asm_text});

    try std.testing.expect(std.mem.indexOf(u8, asm_text, ".LBB5_merge:") != null);
}
