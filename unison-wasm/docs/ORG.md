# Compiler Organization

This document describes the modular structure of the Unison → WASM compiler.

## Design Principles

1. **Single Responsibility**: Each module handles one concern
2. **Layered Dependencies**: Lower modules don't import higher ones
3. **Testability**: Modules can be unit tested in isolation
4. **Navigability**: File names match their purpose

## Module Hierarchy

```
Unison/Wasm/
├── ABI.hs                      # Memory layout, type tags, constants
├── Codebase.hs                 # Load terms from Unison codebase
├── Emit.hs                     # WAT AST and text emission
├── TypeScript.hs               # TypeScript binding generation
├── Compile.hs                  # Entry points + ANormal compilation
└── Compile/
    ├── Builtins.hs             # Builtin → instruction mapping
    ├── Context.hs              # Compilation state and variable bindings
    ├── FFI.hs                  # Foreign function imports
    ├── Literal.hs              # Literal compilation (Nat, Int, Float, Text)
    ├── Match.hs                # Pattern matching (Integral, Data, Request)
    ├── Primitives.hs           # Low-level WASM instruction builders
    └── Runtime.hs              # Runtime support functions (__alloc, __apply, etc.)
```

> **Note:** `Match.hs` uses a callback pattern (`BodyCompiler`) to break the mutual
> recursion with `compileANormal`. This allows it to be a separate module without
> circular imports.

## Module Descriptions

### Core Infrastructure

| Module | Purpose | Key Exports |
|--------|---------|-------------|
| `ABI` | Memory layout spec | `typeTagNat`, `papHeaderSize`, offsets |
| `Emit` | WAT AST types | `WatInstr`, `WatFunction`, `WatModule`, `emitModule` |
| `Codebase` | Term loading | `loadSuperGroup`, `loadDependencies` |

### Compilation Pipeline

| Module | Purpose | Key Exports |
|--------|---------|-------------|
| `Compile` | Orchestration + core | `compileGroup`, `compileMultipleWithLifted`, `compileANormal` |
| `Compile.Context` | State management | `CompileCtx`, `bindVars`, `lookupVar` |
| `Compile.Builtins` | Prim ops | `compilePrimOp`, `builtinToPrimOp` |
| `Compile.FFI` | Foreign imports | `collectForeignCalls`, `foreignFuncsToImports` |
| `Compile.Literal` | Literals | `compileLit`, `compileTextLit` |
| `Compile.Primitives` | Instruction helpers | `loadI64At`, `storeSlot`, `copySlotLoop` |
| `Compile.Runtime` | Runtime funcs | `runtimeFunctions`, `allocPApFunction` |

## Dependency Graph

```
                    ┌─────────┐
                    │ Compile │  (entry point + ANormal/Match)
                    └────┬────┘
                         │
         ┌───────────────┼───────────────┐
         │               │               │
         ▼               ▼               ▼
    ┌──────────┐   ┌──────────┐    ┌─────────┐
    │ Builtins │   │  FFI     │    │ Literal │
    └────┬─────┘   └────┬─────┘    └────┬────┘
         │              │               │
         └──────────────┼───────────────┘
                        │
                        ▼
              ┌────────────────┐
              │    Context     │
              └───────┬────────┘
                      │
                      ▼
              ┌────────────────┐
              │   Primitives   │
              └───────┬────────┘
                      │
           ┌──────────┼──────────┐
           │          │          │
           ▼          ▼          ▼
        ┌─────┐   ┌──────┐   ┌─────────┐
        │ ABI │   │ Emit │   │ Runtime │
        └─────┘   └──────┘   └─────────┘
```

## Current File Sizes

| Module | Lines | Content |
|--------|-------|---------|
| `Compile.hs` | ~1724 | Entry points + ANormal |
| `Compile/Builtins.hs` | ~150 | Primop mapping |
| `Compile/Context.hs` | ~137 | State, bindings |
| `Compile/FFI.hs` | ~263 | Foreign imports |
| `Compile/Literal.hs` | ~68 | Literal handling |
| `Compile/Match.hs` | ~372 | Pattern matching |
| `Compile/Primitives.hs` | ~265 | Instruction helpers |
| `Compile/Runtime.hs` | ~1050 | Runtime functions |

## Adding New Features

### New Primitive Operation
1. Add case to `Compile.Builtins.compilePrimOp`
2. If complex, add helper to `Compile.Primitives`

### New Literal Type
1. Add case to `Compile.Literal.compileLit`
2. Update ABI if new heap layout needed

### New Pattern Match Form
1. Add function to `Compile.Match`
2. Call from `Compile.ANormal.compileANormal`

### New Foreign Function
1. Add to `Compile.FFI.builtinNameToForeignFuncMap`
2. Add signature to `Compile.FFI.foreignFuncSignature`
3. Implement handler in JS runtime

