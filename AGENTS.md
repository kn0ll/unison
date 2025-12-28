# AGENTS.md — WASM Backend Project

This document provides guidance for AI agents working on the Unison WASM compilation backend.

---

## Project Overview

**Goal:** Compile Unison terms to WebAssembly, enabling "one-program fullstack" applications where the same Unison code runs on both server (native) and browser (WASM).

**Key Documents:**
- [`plans/WASM.md`](./plans/WASM.md) — Implementation plan with phased approach
- [`plans/WASM_ABI.md`](./plans/WASM_ABI.md) — Memory layout specification (the ABI contract)

**Current Phase:** Phase 3.5 (Sum Types and Memory) — Not yet started

**Completed Phases:**
- Phase 0: ABI Bootstrap + Conformance Tests ✅
- Phase 1: Arithmetic in WAT ✅
- Phase 2: SuperGroup → WAT Pipeline ✅ (parse → lamLift → superNormalize → factorial(5) = 120)
- Phase 3: IR Improvements ✅ (multi-case MatchNumeric, I32 ops, memory/globals support)

**Test Counts (as of Phase 3 completion):**
- Haskell: 175 tests pass (including factorial, fibonacci, recursion)
- JavaScript: 65 tests pass

---

## Canonical Terminology

To avoid confusion, we use these terms consistently:

| Term | Definition |
|------|------------|
| `ForeignCall` | IR instruction that invokes a JS host function (may yield for async) |
| `Foreign` (object) | Heap object (`OBJ_FOREIGN`) holding an opaque JS handle (passive data) |
| `ContinuationHandle` | JS-side object for resuming an async `ForeignCall` (exactly-once) |
| JS host | The JavaScript environment embedding the WASM module |
| `TypeTag` | 8-bit discriminator for `TypedSlot` payload interpretation (`TYPE_*`) |
| `ObjTag` | 12-bit discriminator for heap object kind (`OBJ_*`) |
| resume | Restore a captured continuation and continue execution |

**Key rules:**
- `ForeignCall` is the instruction; `Foreign` is passive data. Only `ForeignCall` can yield control.
- Never use bare "tag" in prose. Always specify `TypeTag` or `ObjTag`.
- A captured continuation restores exactly the chain of `K` frames and the saved locals segments stored in those frames. There is no implicit operand stack.
- Pointers are 32-bit offsets into linear memory, stored zero-extended in the low 32 bits of `Payload64`.

---

## The Existing Unison Codebase

The Unison codebase is a mature Haskell project with established conventions. When adding WASM support, we must integrate cleanly rather than bolt on a foreign-feeling subsystem.

### Codebase Structure

```
unison/
├── unison-runtime/              # Runtime implementation (PRIMARY FOCUS)
│   ├── src/Unison/Runtime/
│   │   ├── ANF.hs               # SuperGroup, ANormal — our compilation source
│   │   ├── Machine.hs           # Interpreter — reference implementation
│   │   ├── Stack.hs             # Closures, K stack — what we mirror in WASM
│   │   ├── MCode.hs             # MCode generation — patterns to follow
│   │   ├── Builtin.hs           # Builtin function definitions
│   │   ├── Foreign.hs           # Foreign function interface
│   │   └── ANF/
│   │       └── POp.hs           # Primitive operations
│   └── tests/                   # Runtime tests (follow this pattern)
│
├── parser-typechecker/          # Frontend: parsing, typechecking
│   └── src/Unison/
│       ├── Builtin.hs           # Builtin type/term definitions
│       ├── Codebase/Runtime.hs  # Runtime interface abstraction
│       └── Typechecker/         # Type inference
│
├── unison-cli/                  # UCM command-line interface
│   └── src/Unison/Codebase/Editor/
│       ├── HandleInput.hs       # Command dispatch (add compile.wasm here)
│       └── HandleInput/Run.hs   # Execution commands pattern
│
├── unison-core/                 # Core data types (Reference, Term, Type)
├── unison-syntax/               # Parser and printer
│
├── unison-src/                  # Test fixtures and transcripts
│   ├── builtin-tests/           # Builtin function tests
│   ├── transcripts/             # Integration test transcripts
│   └── transcripts-manual/      # Manual test scenarios
│       └── benchmarks/          # Performance benchmarks
│
├── yaks/easytest/               # Custom testing library (USE THIS)
├── lib/                         # Supporting libraries
├── docs/                        # Documentation
└── plans/                       # Design documents (WASM docs here)
```

### Key Files to Study

**Core compilation pipeline (must read):**

| File | Why It Matters |
|------|----------------|
| `Runtime/ANF.hs` | Defines `SuperGroup` and `ANormal` — our input IR |
| `Runtime/Stack.hs` | Defines closure representations (`GClosure`, `K`) — what we emit |
| `Runtime/Machine.hs` | The interpreter — our behavioral reference |
| `Runtime/MCode.hs` | Shows how to traverse and emit from `SuperGroup` |
| `Runtime/ANF/POp.hs` | Primitive operations we must support |

**Foreign function interface (for JS interop):**

| File | Why It Matters |
|------|----------------|
| `Runtime/Builtin.hs` | How builtins are registered and wired |
| `Runtime/Foreign.hs` | Foreign value wrapping patterns |

**Adding UCM commands (for `compile.wasm`):**

| File | Why It Matters |
|------|----------------|
| `Codebase/Editor/HandleInput.hs` | Command dispatch — add new commands here |
| `Codebase/Editor/HandleInput/Run.hs` | Pattern for execution-related commands |
| `Codebase/Editor/Input.hs` | Command input type definitions |
| `Codebase/Editor/Output.hs` | Command output type definitions |

**Testing patterns (follow these):**

| File | Why It Matters |
|------|----------------|
| `unison-runtime/tests/Suite.hs` | Test entry point pattern |
| `unison-runtime/tests/Unison/Test/Runtime/ANF.hs` | Example test module |
| `unison-src/transcripts/` | Integration test patterns |

### Fitting In: Code Style

**Follow existing patterns. Do not introduce new styles.**

1. **Module naming:** Use `Unison.Wasm.*` namespace
   ```haskell
   module Unison.Wasm.Compile where  -- Good
   module Wasm.Compile where          -- Bad: breaks convention
   ```

2. **Import style:** Match the existing qualified import patterns
   ```haskell
   import qualified Data.Map as Map
   import qualified Unison.Runtime.ANF as ANF
   ```

3. **Type naming:** Follow existing conventions
   ```haskell
   data WSection = ...  -- Mirrors GSection pattern
   data WInstr = ...    -- Mirrors MInstr pattern
   ```

4. **Function naming:** Use camelCase, descriptive names
   ```haskell
   emitFunction :: SuperNormal -> WSection  -- Mirrors emitSection
   compileGroup :: SuperGroup -> WModule
   ```

5. **Error handling:** Use the existing error patterns from `Runtime/`

### Fitting In: Architecture

**Do not reinvent what already exists.**

1. **Reuse IR types:** Work with `SuperGroup`/`ANormal` directly. Do not create a new IR unless absolutely necessary.

2. **Mirror closure representations:** Our WASM layouts in `WASM_ABI.md` are designed to mirror `GClosure` variants exactly. Keep this correspondence.

3. **Match interpreter semantics:** When in doubt about behavior, check `Machine.hs`. Our WASM output must produce identical results.

4. **Use existing primitive definitions:** Import from `Runtime/ANF/POp.hs` rather than redefining primitives.

### Fitting In: Build System

The project uses Stack with Cabal files:

1. **New package location:** `unison-wasm/` at repository root
2. **Add to stack.yaml:** Include in `packages:` list
3. **Dependencies:** Depend on `unison-runtime` to access `SuperGroup`
4. **Cabal file pattern:** Follow `unison-runtime/unison-runtime.cabal` structure

```yaml
# In stack.yaml, add:
packages:
  - unison-wasm
```

```cabal
-- unison-wasm/unison-wasm.cabal
name:           unison-wasm
version:        0.1.0.0
build-depends:
  , unison-runtime
  , unison-core
  -- ...
```

---

## Implementation Guidelines

### Phase-by-Phase Verification

**Every phase has an interactive verification checkpoint.** Do not proceed to the next phase until the current phase's checkpoint passes and a human confirms.

### ABI is Sacred

The `WASM_ABI.md` specification is a contract. Once Phase 0 tests pass:
- Any layout change requires updating the spec first
- Both Haskell and JS code must regenerate constants from spec
- Breaking the ABI requires a version bump

### Naming Conventions in ABI

| Prefix | Meaning | Example |
|--------|---------|---------|
| `TYPE_*` | TypeTag value (slot payload interpretation) | `TYPE_NAT`, `TYPE_BOXED` |
| `OBJ_*` | ObjTag value (heap object kind) | `OBJ_ENUM`, `OBJ_DATA1` |
| `FRAME_*` | K frame type | `FRAME_PUSH`, `FRAME_MARK` |

**Rule:** Never use bare "tag" in prose or code comments. Always specify `TypeTag` or `ObjTag`.

---

## Testing Standards

The Unison project has specific testing conventions. The WASM backend must follow these.

### Haskell Tests (EasyTest)

Unison uses a custom testing library called **EasyTest** (in `yaks/easytest/`). All Haskell tests must use this library.

**Test module structure:**

```haskell
-- unison-wasm/tests/Unison/Test/Wasm/Emit.hs
module Unison.Test.Wasm.Emit where

import EasyTest
import Unison.Wasm.Emit qualified as Emit

test :: Test ()
test =
  scope "emit" . tests $
    [ scope "instruction" . tests $
        [ scope "i64.add" $ expect (Emit.instr Add64 == "i64.add"),
          scope "i64.const" $ expect (Emit.const64 42 == "i64.const 42")
        ],
      scope "function" . tests $
        [ testEmitIncrement
        ]
    ]

testEmitIncrement :: Test ()
testEmitIncrement = scope "increment" $ do
  let wat = Emit.emitFunction incrementSuperNormal
  expect (wat `contains` "i64.add")
```

**Key EasyTest combinators:**

| Combinator | Usage |
|------------|-------|
| `scope "name"` | Name a test or group |
| `tests [...]` | Combine multiple tests |
| `expect condition` | Assert a boolean |
| `expectEqual a b` | Assert equality |
| `ok` | Pass unconditionally |
| `crash msg` | Fail with message |
| `io action` | Run IO in test |

**Test suite entry point:**

```haskell
-- unison-wasm/tests/Suite.hs
module Main where

import EasyTest
import System.IO
import System.IO.CodePage (withCP65001)
import Unison.Test.Wasm.Emit qualified as Emit
import Unison.Test.Wasm.Compile qualified as Compile
import Unison.Test.Wasm.ABI qualified as ABI

test :: Test ()
test =
  tests
    [ Emit.test,
      Compile.test,
      ABI.test
    ]

main :: IO ()
main = withCP65001 do
  mapM_ (`hSetEncoding` utf8) [stdout, stdin, stderr]
  runOnly "" test
```

**Package.yaml test configuration:**

```yaml
# unison-wasm/package.yaml
tests:
  wasm-tests:
    source-dirs: tests
    main: Suite.hs
    ghc-options: -W -threaded -rtsopts "-with-rtsopts=-N -T" -v0
    dependencies:
      - base
      - easytest
      - unison-wasm
      - unison-runtime
      - unison-core1
      # ... other deps
```

**Running Haskell tests:**

```bash
# Run all WASM tests
$ stack test unison-wasm

# Run tests matching a scope prefix
$ stack test unison-wasm --test-arguments "emit.instruction"

# Run with a specific seed for reproducibility
$ stack test unison-wasm --test-arguments "12345 emit"
```

### JavaScript/TypeScript Tests (Phase 0+ and WASM verification)

Phase 0+ and WASM runtime verification use TypeScript with Node.js built-in test runner.

```javascript
// unison-wasm/js/tests/abi.test.js
import { describe, it, before } from 'node:test';
import assert from 'node:assert/strict';
import { createHeapAllocator, allocEnum, decodeObject } from '../dist/index.js';
import { OBJ_ENUM, TYPE_NAT } from '../dist/abi-constants.js';

describe('ABI Conformance', () => {
  let memory, alloc;

  before(() => {
    memory = new WebAssembly.Memory({ initial: 1 });
    alloc = createHeapAllocator(memory, 0x1000);
  });

  describe('Enum layout', () => {
    it('allocates with correct header', () => {
      const ptr = alloc.allocEnum(0x100, 1);
      const obj = decodeObject(memory.buffer, ptr);
      assert.strictEqual(obj.objTag, OBJ_ENUM);
    });

    it('is 8-byte aligned', () => {
      const ptr = alloc.allocEnum(0x100, 0);
      assert.strictEqual(ptr % 8, 0);
    });
  });
});
```

**Running JavaScript tests:**

```bash
# From unison-wasm/js/
$ npm test

# Runs: tsc && node --test tests/
```

### Test Directory Structure

```
unison-wasm/
├── tests/                          # Haskell tests (EasyTest)
│   ├── Suite.hs                    # Main entry point
│   └── Unison/
│       └── Test/
│           └── Wasm/
│               ├── ABI.hs          # ABI constants tests
│               ├── Compile.hs      # SuperGroup compilation tests
│               └── Emit.hs         # WAT emission tests
│
├── js/                             # TypeScript/JavaScript runtime
│   ├── package.json
│   ├── tsconfig.json               # Strict TypeScript config
│   ├── src/                        # TypeScript source
│   │   ├── index.ts                # Re-exports
│   │   ├── abi-constants.ts        # ABI constants (single source of truth)
│   │   ├── wasm-alloc.ts           # Heap allocators
│   │   ├── wasm-debug.ts           # Memory inspector/decoders
│   │   └── errors.ts               # Error classes
│   ├── dist/                       # Compiled JavaScript output
│   └── tests/                      # Node.js tests
│       ├── abi.test.js             # ABI conformance tests (Phase 0)
│       └── wat.test.js             # WAT execution tests (Phase 1+2)
│
└── app/                            # CLI executable
    └── Main.hs                     # unison-wasm-poc
```

### What to Test Where

| Test Type | Location | Framework |
|-----------|----------|-----------|
| IR traversal, codegen logic | `tests/` (Haskell) | EasyTest |
| WAT text emission | `tests/` (Haskell) | EasyTest |
| ABI layout conformance | `js/tests/` (TS) | node:test |
| WASM execution correctness | `js/tests/` (TS) | node:test + wabt |
| Memory inspector | `js/tests/` (TS) | node:test |
| Async/continuation handling | `js/tests/` (TS) | node:test |

### Behavioral Equivalence Tests

For correctness, WASM output must match the Haskell interpreter. Create equivalence tests:

```haskell
-- tests/Unison/Test/Wasm/Equivalence.hs
testEquivalence :: SuperGroup Symbol -> Test ()
testEquivalence sg = scope "equivalence" $ do
  -- Run through Haskell interpreter
  let expected = runInterpreter sg
  -- Compile to WASM and run
  let wasm = compileToWasm sg
  actual <- io $ runWasmModule wasm
  expectEqual expected actual
```

### Continuous Integration

Tests run on every PR. Ensure:

1. `stack test unison-wasm` passes (175 tests as of Phase 3)
2. `npm test` in `unison-wasm/js/` passes (79 tests as of Phase 2)
3. No new compiler warnings
4. Code formatted with project standards

---

## Common Pitfalls

### 1. Forgetting the TypeTag

Every value in WASM is a `TypedSlot` (16 bytes: TypeTag + Payload64). Do not store raw i64 values without the TypeTag.

```
Wrong: store just the i64 value
Right: store TypeTag (8 bytes padded) + Payload64 (8 bytes)
```

### 2. Pointer Size Confusion

Pointers are 32-bit offsets into linear memory, stored zero-extended in the low 32 bits of `Payload64`:
- Store pointer in **low 32 bits**
- High 32 bits are **always zero**
- Never truncate and lose the high bits — they should already be zero

### 3. Async Continuation Linearity

Async foreign calls capture a continuation that must be resumed **exactly once**:
- JS runtime enforces this with `ContinuationHandle.consumed` flag
- Double-resume throws `ContinuationConsumedError`
- No nested async calls allowed in MVP

### 4. Confusing K Frames with Stack Frames

| Concept | What It Is | Where It Lives |
|---------|------------|----------------|
| Stack frame | Function's local variables | Contiguous memory region |
| K frame | Return address + saved state | Linked list in heap |

`K` frames are for control (returns, handlers). Stack frames are for data (locals).

### 5. Ability Handler Confusion

Most abilities run **entirely in WASM** — only `ForeignCall` operations yield to JS:
- `Counter`, `State`, custom abilities → Unison handler in `DEnv` → WASM only
- `IO.printLine`, `fetch` → `ForeignCall` → yields to JS

### 6. Phase 2 Shortcuts Still in Code

Phase 2 took shortcuts that must be fixed in Phase 3:

| Shortcut | Location | Fix in Phase 3 |
|----------|----------|----------------|
| `BX` → `I64` | `Compile.hs:132` | Change to `I32` for 32-bit pointers |
| `TBLit` unboxed | `Compile.hs:408` | Allocate as TypedSlot with TypeTag |
| Single-case `MatchNumeric` | `Compile.hs:528-532` | Full if/else chain or br_table |

Don't be surprised if you see boxed values treated as i64 — it's intentional Phase 2 debt.

### 7. Forgetting Apply for Closures

JS cannot directly call closures returned by Unison. Use the `apply()` export:

```javascript
// Wrong: trying to call closure directly
const handler = widget.onClick;
handler();  // Error: handler is a pointer, not a function

// Right: use runtime.apply()
const handler = widget.onClick;
runtime.apply(handler);  // Correct
```

The `apply()` function:
- Reads arity from PAp header
- Type-checks args at runtime
- Returns result or new PAp (if partially applied)
- Handles async yield if closure triggers ForeignCall

TypeScript provides compile-time safety for apply calls.

---

## Quick Reference: Phase 2 Parsing Pipeline

The full compilation pipeline from Unison source to WASM:

```
Unison source string
    ↓ Parser.run (Parser.root TermParser.term)
Term v
    ↓ splitPatterns builtinDataSpec
Term v (pattern desugaring)
    ↓ lamLift mempty
(Set Reference, SuperGroup v) (lifted combinators + main)
    ↓ superNormalize
(main: SuperGroup v, lifted: Map Reference SuperGroup)
    ↓ compileGroupWithLifted
WAT module (multiple functions if lambda-lifted)
    ↓ wabt (JS)
WASM binary
```

**Key functions in `/workspaces/unison/unison-wasm/`:**
- `Main.hs`: `parseTerm`, `termToSuperGroup`, `parseAndCompile`
- `Compile.hs`: `compileGroupWithLifted`, `builtinToPrimOp`, `refToFuncName`

**CLI commands:**
```bash
# Compile from actual Unison source (Phase 2 achievement)
stack exec unison-wasm-poc -- compile factorial \
    'let go n = match n with 0 -> 1; _ -> ##Nat.* n (go (##Nat.sub n 1)); go 5'

# Debug SuperGroup structure
stack exec unison-wasm-poc -- debug '<unison code>'

# Legacy hardcoded SuperGroups
stack exec unison-wasm-poc -- emit-factorial
```

---

## Checklist Before Submitting Changes

**Code Quality:**
- [ ] Code follows existing Unison Haskell style
- [ ] New modules use `Unison.Wasm.*` namespace
- [ ] No new compiler warnings introduced

**ABI Compliance:**
- [ ] ABI changes update `WASM_ABI.md` first
- [ ] Constants regenerated from spec after ABI changes
- [ ] Memory inspector confirms correct layouts

**Testing:**
- [ ] `stack test unison-wasm` passes
- [ ] `npm test` in `js/` passes (if JS changes)
- [ ] New Haskell tests use EasyTest with proper `scope`
- [ ] Test modules follow `Unison.Test.Wasm.*` namespace
- [ ] Behavioral equivalence verified against interpreter

**Phase Gates:**
- [ ] Phase verification checkpoint passes
- [ ] Human has confirmed checkpoint before proceeding

---

## Quick Reference: Type Mappings

| Unison/Runtime | WASM ABI | Size |
|----------------|----------|------|
| `Val` | `TypedSlot` | 16 bytes |
| `UnboxedTypeTag` | `TYPE_*` constants | 1 byte |
| `GEnum` | `OBJ_ENUM` | 16 bytes |
| `GData1` | `OBJ_DATA1` | 32 bytes |
| `GData2` | `OBJ_DATA2` | 48 bytes |
| `GDataG` | `OBJ_DATAG` | 16 + N*16 bytes |
| `GPAp` | `OBJ_PAP` | 24 + N*16 bytes |
| `GCaptured` | `OBJ_CAPTURED` | 16 + N*16 bytes |
| `GForeign` | `OBJ_FOREIGN` | 16 bytes |
| `data K` | `FRAME_*` linked list | variable |

**Note:** PAp includes `ExpectedArity`/`CapturedCount` for the `apply()` protocol.

---

## Getting Help

1. **Behavioral questions:** Check `Machine.hs` interpreter
2. **IR structure questions:** Check `ANF.hs` types
3. **Memory layout questions:** Check `WASM_ABI.md`
4. **Implementation plan questions:** Check `WASM.md`
5. **Code style questions:** Check existing `unison-runtime/` code

