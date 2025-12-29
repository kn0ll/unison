# Unison WASM Backend

Compile Unison terms to WebAssembly, enabling **"one-program fullstack"** applications where the same Unison code runs on both server (native) and browser (WASM).

## Quick Start

### Run the Demo

```bash
cd demo
npm install
npm run dev
# Open http://localhost:3001
```

The demo shows a Price Calculator where:
- **Browser** calculates prices instantly (WASM)
- **Server** verifies with the same WASM module
- **Drift Mode** simulates what happens with duplicated code
- **Foreign Calls** (`IO.printNat`) log to console in both environments

### Run Tests

```bash
# Haskell tests
stack test unison-wasm

# JavaScript tests
cd js && npm test
```

### Compile Unison to WASM

```bash
# Build the CLI
stack build unison-wasm

# Compile an expression
stack exec unison-wasm-poc -- compile myFunc 'x -> ##Nat.+ x 1'

# Output: WAT module to stdout
```

---

## Architecture

```
Unison Source → SuperGroup (ANF) → WAT → WASM Binary
                     ↓
              unison-wasm-poc (Haskell)
                     ↓
              wat2wasm (wabt)
```

---

## Supported Features

### Compilation (Haskell → WAT)

| Feature | Status | Notes |
|---------|--------|-------|
| Arithmetic (`Nat.+`, `Nat.*`, etc.) | ✅ | All numeric primitives |
| Pattern matching | ✅ | Boolean, numeric, sum types |
| Recursion | ✅ | Tail and non-tail |
| Closures | ✅ | PAp allocation, partial application |
| Higher-order functions | ✅ | `map`, `fold`, etc. |
| Abilities (effects) | ✅ | THnd, TShift, capture/resume |
| Foreign calls | ✅ | Sync JS function calls |
| Async foreign calls | ✅ | Yield/resume with ContinuationHandle |

### JavaScript Runtime

| Feature | Status | Notes |
|---------|--------|-------|
| `UnisonRuntime` class | ✅ | Load WASM, provide imports |
| `apply()` | ✅ | Call closures with type checking |
| `allocText()` | ✅ | Allocate Text in WASM memory |
| `exposeToDevTools()` | ✅ | Debug in browser console |
| `ContinuationHandle` | ✅ | Resume async foreign calls |
| TypeScript definitions | ✅ | `.d.ts` generation from types |

---

## Project Structure

```
unison-wasm/
├── src/Unison/Wasm/           # Haskell compiler
│   ├── Compile.hs             # SuperGroup → WAT compilation
│   ├── Emit.hs                # WAT text emission
│   ├── ABI.hs                 # ABI constants (generated)
│   └── Compile/
│       └── Runtime.hs         # Runtime functions (__apply, __alloc, etc.)
│
├── app/Main.hs                # CLI (unison-wasm-poc)
│
├── tests/                     # Haskell tests (EasyTest)
│   ├── Suite.hs
│   └── Unison/Test/Wasm/
│       ├── Compile.hs         # Compilation tests
│       ├── Abilities.hs       # E2E ability tests (wasmtime)
│       └── Fixtures.hs        # .u file tests
│
├── tests/fixtures/            # Unison test files
│   ├── arithmetic/
│   ├── recursion/
│   ├── closures/
│   └── pattern-matching/
│
├── js/                        # TypeScript runtime
│   ├── src/
│   │   ├── runtime.ts         # UnisonRuntime class
│   │   ├── continuation.ts    # ContinuationHandle
│   │   └── abi-constants.ts   # ABI constants (single source)
│   └── tests/                 # Node.js tests
│
└── demo/                      # Integration demo
    ├── index.html             # Price Calculator UI
    ├── demo.ts                # Browser TypeScript
    ├── server.ts              # Node.js Express server
    ├── src/pricing.u          # THE SHARED UNISON CODE
    └── build-wasm.sh          # WASM build script
```

---

## Terminology

| Term | Definition |
|------|------------|
| `ForeignCall` | IR instruction that invokes a JS host function (may yield for async) |
| `Foreign` (object) | Heap object holding an opaque handle to a JS value |
| `ContinuationHandle` | JS-side object for resuming an async `ForeignCall` |
| `K` | Continuation stack — linked list of frames in linear memory |
| `TypeTag` | 8-bit discriminator for `TypedSlot` payload interpretation |
| `ObjTag` | 12-bit discriminator for heap object kind |
| `TypedSlot` | 16-byte (TypeTag + Payload64) pair — universal value representation |

---

## Memory Layout (ABI)

See [`ABI.md`](./ABI.md) for full specification.

### TypedSlot (16 bytes)

```
Offset 0:  TypeTag (1 byte) + padding (7 bytes)
Offset 8:  Payload64 (8 bytes)
```

### Heap Objects

| ObjTag | Name | Size | Purpose |
|--------|------|------|---------|
| 0x001 | OBJ_ENUM | 16 | Nullary constructor |
| 0x002 | OBJ_DATA1 | 32 | Unary constructor |
| 0x003 | OBJ_DATA2 | 48 | Binary constructor |
| 0x004 | OBJ_DATAG | 16+N×16 | N-ary constructor |
| 0x005 | OBJ_PAP | 24+N×16 | Partial application |
| 0x006 | OBJ_CAPTURED | variable | Captured continuation |
| 0x00A | OBJ_FOREIGN | 16 | Opaque JS handle |
| 0x00B | OBJ_ASYNC_CONT | 24 | Async continuation |

---

## Compilation Pipeline

```
1. Parse Unison source
2. Lambda lift → SuperGroup
3. SuperNormalize → ANormal
4. Compile to WAT instructions
5. Emit WAT text
6. (Optional) wat2wasm → WASM binary
```

### Key Compilation Rules

| ANormal Node | WASM Emission |
|--------------|---------------|
| `TVar v` | `local.get $v` |
| `TLit (N n)` | `i64.const n` |
| `TPrm ADDN [a,b]` | emit(a); emit(b); `i64.add` |
| `TApp (FComb ref) args` | emit(args); `call $ref` |
| `TMatch v branches` | `br_table` or `if/else` chain |
| `THnd rs handler body` | Push Mark frame, install handler |
| `TShift r v e` | Capture K up to Mark, bind to v |
| `TFOp foreignFunc args` | `call $foreignFunc` (imported) |
