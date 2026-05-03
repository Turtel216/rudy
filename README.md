# Rudy

> An educational, LLVM-inspired compiler infrastructure framework written in Zig.

**Rudy** is a modular compiler framework designed to explore the internals of compiler design, Intermediate Representation (IR) construction, and machine code generation. Built natively in [Zig](https://ziglang.org/), Rudy aims to provide a clean, readable, and highly performant foundation for language frontends to target.

While currently in its early stages as an educational project, Rudy is built with a target-independent backend architecture, in order to add multi-ISA support and extensible optimization passes in the future.

## Current Status & Features

Rudy is actively under development. The following foundational features have been implemented:

* **Intermediate Representation (IR):** A clean, simple, and strictly defined IR designed for easy analysis and transformation.
* **Ergonomic IR Builder:** A programmable API (similar to `LLVMBuilder`) for language frontends to easily construct IR and basic blocks.
* **Control Flow Graph (CFG) Basics:** Support for basic blocks, branching, and conditional jumps.
* **Pluggable Backend Architecture:** The backend interface is designed to be target-agnostic, allowing new instruction set architectures (ISAs) to be slotted in cleanly.
* **x86 Code Emission:** The first implemented backend, currently capable of lowering Rudy IR to x86 machine code.

## Architecture Overview

Rudy loosely follows the classic three-phase compiler design popularized by LLVM:

1. **Frontend (Provided by the User):** Parses source code into an Abstract Syntax Tree (AST) and uses Rudy's `Builder` API to generate Rudy IR.
2. **Middle-end (IR):** The SSA based IR represents the program in a target-independent way. *(Note: Optimization passes will be introduced here in the future).*
3. **Backend (Target Machine):** Lowers the IR into machine-specific instructions. Currently implemented for x86, the abstraction layer ensures that adding ARM or RISC-V support in the future requires minimal changes to the core framework.

## Roadmap / Future Work

Because Rudy is an ongoing educational journey, the roadmap is fluid. Immediate next steps include:

- [x] **Static Single Assignment (SSA):** Transitioning the IR strictly into SSA form for easier data-flow analysis.
- [x] **Register Allocation:** Implementing a Linear Scan register allocator.
- [ ] **Optimization Passes:** Adding foundational middle-end passes like Dead Code Elimination (DCE) and Constant Folding.
- [ ] **Expanded x86 Support:** Broadening the supported instruction set and addressing modes.
- [ ] **New Backends:** Experimenting with an ARM64 or RISC-V backend to validate the target-agnostic design.

## Building the Project

Ensure you have the latest version of [Zig](https://ziglang.org/download/) installed. 

To build the project:

```bash
# Build the library and executable
zig build

# Run the tests
zig build test
```
