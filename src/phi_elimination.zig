//! Phi Node Elimination Pass
//!
//! This pass operates on Machine IR after
//! instruction selection but before register allocation.  It eliminates
//! SSA phi nodes by inserting copy (MOV) instructions at the end of each
//! predecessor basic block, just before the terminator sequence.
//!
//! The pass is generic: it is parameterised on the target's machine
//! instruction type, register type, and two target-supplied callbacks
//! (`createCopy` and `isTerminator`), so the same algorithm can be
//! reused across x86_64, AArch64, RISC-V, etc.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");
const backend = @import("backend.zig");

/// Instantiate a phi-elimination pass for a concrete target.
///
/// Type parameters:
///   - `MachineInstr`: the target's machine instruction type.
///   - `Reg`:          the target's register type (virtual | physical union).
///
/// Function parameters (comptime):
///   - `createCopy`:   builds a `MOV dst, src` machine instruction.
///   - `isTerminator`: returns `true` for branch/return instructions.
pub fn PhiElimination(
    comptime MachineInstr: type,
    comptime Reg: type,
    comptime createCopy: fn (Allocator, dst: Reg, src: Reg) anyerror!MachineInstr,
    comptime isTerminator: fn (MachineInstr) bool,
) type {
    return struct {
        const MBB = backend.MachineBasicBlock(MachineInstr);
        const MFunc = backend.MachineFunction(MachineInstr);

        /// Run phi elimination over the entire machine function.
        ///
        /// For every phi node in the original IR, a copy instruction is
        /// inserted at the end of each predecessor machine block (before
        /// the terminator sequence).  Because the current ISel emits no
        /// machine code for phi nodes, there is nothing to remove from
        /// the merge blocks — the phi vregs are simply populated by the
        /// newly inserted copies.
        ///
        /// Preconditions:
        ///   - `mf` blocks are in 1:1 correspondence with `ir_func` blocks.
        ///   - Every SSA value referenced by a phi is present in `vreg_map`.
        pub fn run(
            alloc: Allocator,
            mf: *MFunc,
            ir_func: *const ir.Function,
            vreg_map: *const std.AutoHashMap(u32, Reg),
        ) !void {
            for (ir_func.blocks.items) |ir_block| {
                for (ir_block.insts.items) |inst_idx| {
                    const inst = ir_func.getInst(inst_idx);

                    switch (inst) {
                        .phi => |phi| {
                            const dst_reg = vreg_map.get(inst_idx.toInt()) orelse
                                return error.UnmappedPhiDst;

                            for (phi.incoming_values, phi.incoming_blocks) |val_idx, pred_blk| {
                                const src_reg = vreg_map.get(val_idx.toInt()) orelse
                                    return error.UnmappedPhiSrc;

                                // Get the predecessor machine basic block.
                                const pred_mbb = mf.getBlock(pred_blk.toInt());

                                // Create a MOV dst, src.
                                const copy_mi = try createCopy(alloc, dst_reg, src_reg);

                                // Insert just before the terminator sequence.
                                const insert_pos = findInsertionPoint(pred_mbb);
                                try pred_mbb.insts.insert(alloc, insert_pos, copy_mi);
                            }
                        },
                        else => {},
                    }
                }
            }
        }

        /// Scan backwards from the end of `mbb` to find the first
        /// instruction that is *not* a terminator.  The returned index
        /// is the position just after that instruction — i.e. the
        /// correct insertion point for phi-copy MOVs.
        fn findInsertionPoint(mbb: *MBB) usize {
            var pos = mbb.insts.items.len;
            while (pos > 0) {
                if (isTerminator(mbb.insts.items[pos - 1])) {
                    pos -= 1;
                } else {
                    break;
                }
            }
            return pos;
        }
    };
}
