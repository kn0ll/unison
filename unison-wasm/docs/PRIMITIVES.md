# Primitive Operations

> How to find and implement Unison primitives for the WASM backend.

---

## Overview

Unison's runtime uses **primitive operations (POps)** for low-level operations that can't be expressed in pure Unison. The WASM compiler must translate these to WebAssembly instructions or runtime calls.

```
Unison source → ANF (TPrm ADDN [a, b]) → WASM (i64.add)
```

---

## Finding Primitives

### 1. The Canonical List

All primitives are defined in:

```
unison-runtime/src/Unison/Runtime/ANF/POp.hs
```

```haskell
data POp
  = ADDN  -- Nat.+
  | SUBN  -- Nat.-
  | MULN  -- Nat.*
  -- ... more
```

### 2. What Each Primitive Does

The interpreter implementation shows the semantics:

```
unison-runtime/src/Unison/Runtime/Machine.hs
```

Search for `eval1` or the primitive name to see how the native runtime handles it.

### 3. Mapping to Builtins

To see which Unison function maps to which primitive:

```
parser-typechecker/src/Unison/Builtin.hs      -- Type signatures
unison-runtime/src/Unison/Runtime/Builtin.hs  -- POp mappings
```

---

## Current Status

### Check What's Implemented

```bash
# List all primitives we handle
grep -E 'compilePrimOp [A-Z]{4}' src/Unison/Wasm/Compile.hs | \
  sed 's/.*compilePrimOp //' | sed 's/ .*//' | sort -u

# List all primitives that exist
grep -E '^\s+\| [A-Z]{4}' ../unison-runtime/src/Unison/Runtime/ANF/POp.hs | \
  sed 's/.*| //' | sed 's/ --.*//' | sort -u
```

### Current Coverage

| Category | Implemented | Total | Status |
|----------|-------------|-------|--------|
| Nat arithmetic | 8 | 8 | ✅ |
| Int arithmetic | 8 | 10 | 🔶 |
| Float arithmetic | 8 | 32 | 🔶 |
| Bitwise | 0 | 17 | ❌ |
| Text ops | 0 | 9 | ❌ |
| Sequence ops | 0 | 14 | ❌ |
| Bytes ops | 0 | 9 | ❌ |
| Debug | 2 | 4 | 🔶 |
| Other | 0 | ~40 | ❌ |

---

## How to Implement a Primitive

### Step 1: Understand the Semantics

Look at the interpreter in `Machine.hs`:

```haskell
-- Example: ADDN (Nat addition)
eval1 _ ADDN = unsafeIO $ do
  m <- peekOffN stk 0
  n <- peekOffN stk 1
  pokeN stk (m + n)
```

This tells you: ADDN pops two Nats, adds them, pushes result.

### Step 2: Determine the Strategy

| Type | Strategy | Example |
|------|----------|---------|
| **Direct WASM op** | Emit single instruction | `ADDN → i64.add` |
| **Multi-instruction** | Emit instruction sequence | Float comparison → `f64.lt` + `i64.extend_i32_u` |
| **Runtime call** | Call helper function | `BLDS → call $__build_list` |
| **FFI call** | Import from JS | `TRCE → call $Debug_trace` |

### Step 3: Add to Compile.hs

```haskell
-- In compilePrimOp:

-- Direct WASM op
compilePrimOp ADDN 2 = pure I64Add

-- Multi-instruction sequence
compilePrimOp SQRT 1 = pure $ F64Sqrt  -- but need reinterpret wrapper

-- Unsupported (will error at compile time)
compilePrimOp op _n = Left $ UnsupportedPrimOp op
```

### Step 4: Handle Type Conversions

Unison stores everything as `i64`. Floats are reinterpreted:

```haskell
-- Float operations need conversion wrapper
floatUnaryOp :: WatInstr -> [WatInstr]
floatUnaryOp op =
  [ F64ReinterpretI64  -- i64 → f64
  , op                 -- do the operation
  , I64ReinterpretF64  -- f64 → i64
  ]
```

### Step 5: Add Tests

```haskell
-- In tests/Unison/Test/Wasm/Compile.hs
scope "primitives.sqrt" $ do
  let code = "x -> Float.sqrt x"
  result <- compileAndRun code [floatArg 4.0]
  expectEqual result (floatResult 2.0)
```

---

## Implementation Patterns

### Pattern 1: Direct Mapping (Easiest)

For primitives that map 1:1 to WASM instructions:

```haskell
compilePrimOp ADDN 2 = pure I64Add
compilePrimOp SUBN 2 = pure I64Sub
compilePrimOp ANDN 2 = pure I64And
compilePrimOp SHRN 2 = pure I64ShrU
```

### Pattern 2: Float Operations

Floats are stored as reinterpreted i64, so need wrapping:

```haskell
compilePrimOp SQRT 1 = pure $ floatUnaryOp F64Sqrt
compilePrimOp ADDF 2 = pure $ floatBinOp F64Add

floatUnaryOp op = [F64ReinterpretI64, op, I64ReinterpretF64]
floatBinOp op =
  [ LocalSet "__float_temp"   -- save second arg
  , F64ReinterpretI64         -- convert first arg
  , LocalGet "__float_temp"
  , F64ReinterpretI64         -- convert second arg
  , op                        -- do operation
  , I64ReinterpretF64         -- convert result back
  ]
```

### Pattern 3: Comparison Operations

WASM comparisons return i32, Unison expects i64:

```haskell
compilePrimOp LESN 2 = pure I64LtU  -- returns i32
-- But we need to extend to i64:
-- Actually handled by the caller context
```

### Pattern 4: Runtime Helper Calls

For complex operations, call a runtime function:

```haskell
compilePrimOp BLDS n = pure $ buildListCall n
  where
    buildListCall n =
      [ I32Const (fromIntegral n)  -- element count
      , Call "__build_list"        -- runtime helper
      ]
```

The helper function is defined in `Compile/Runtime.hs`.

### Pattern 5: FFI Calls

For operations that need JavaScript:

```haskell
compilePrimOp TRCE 2 = pure $ Call "Debug_trace"
```

Also need to:
1. Add to import collection (`collectDebugBuiltins`)
2. Add import generation (`debugBuiltinsToImports`)
3. Provide JS handler in runtime

---

## Heap-Allocated Types

Some primitives work with heap objects. See `ABI.md` for layouts.

### Text

```
Header (8 bytes) | ByteLen (4) | CharLen (4) | UTF-8 bytes...
```

Primitives: `CATT`, `TAKT`, `DRPT`, `SIZT`, `PAKT`, `UPKT`

Need runtime helpers for:
- Allocation (`__alloc_text`)
- Concatenation (`__concat_text`)
- Slicing

### Sequence/List

```
Header (8 bytes) | Length (4) | Elements...
```

Primitives: `BLDS`, `CONS`, `SNOC`, `CATS`, `TAKS`, `DRPS`, `IDXS`, `SIZS`

Complex: Unison uses finger trees, WASM MVP can use simple arrays.

### Bytes

```
Header (8 bytes) | Length (4) | Raw bytes...
```

Primitives: `CATB`, `TAKB`, `DRPB`, `SIZB`, `IDXB`, `PAKB`, `UPKB`

---

## Adding a New Category

### Example: Adding Bitwise Operations

1. **Check the primitives exist:**
   ```bash
   grep -E 'AND|IOR|XOR|SH' unison-runtime/src/Unison/Runtime/ANF/POp.hs
   ```

2. **Add cases to `compilePrimOp`:**
   ```haskell
   -- Nat bitwise
   compilePrimOp ANDN 2 = pure I64And
   compilePrimOp IORN 2 = pure I64Or
   compilePrimOp XORN 2 = pure I64Xor
   compilePrimOp SHLN 2 = pure I64Shl
   compilePrimOp SHRN 2 = pure I64ShrU

   -- Int bitwise (same ops, different semantics for shift)
   compilePrimOp ANDI 2 = pure I64And
   compilePrimOp SHRI 2 = pure I64ShrS  -- arithmetic shift
   ```

3. **Add to builtinToPrimOp (if needed):**
   ```haskell
   builtinToPrimOp "Nat.and" 2 = Just [I64And]
   ```

4. **Test:**
   ```bash
   stack test unison-wasm --test-arguments='--pattern primitives.bitwise'
   ```

---

## Primitives Requiring Special Handling

Some primitives need platform-specific implementations:

### Mutable References (`REFN/REFR/REFW/RCAS`)

| Primitive | Unison | Strategy |
|-----------|--------|----------|
| `REFN` | `Ref.new` | FFI → JS `Map<id, value>` |
| `REFR` | `Ref.read` | FFI → `map.get(id)` |
| `REFW` | `Ref.write` | FFI → `map.set(id, value)` |
| `RCAS` | `Ref.cas` | FFI → compare-and-swap in JS |

**Works in browser**: ✅ Yes, via FFI to JS runtime.

### Threading (`TFRC`, `ATOM`)

| Primitive | Unison | Strategy |
|-----------|--------|----------|
| `TFRC` | Try force (evaluate thunk on another thread) | Web Workers + SharedArrayBuffer |
| `ATOM` | STM atomically | Single-threaded: no-op wrapper |

**Works in browser**: ⚠️ Partially. Single-threaded code works. True parallelism needs Workers.

### Code Caching (`CACH/LKUP/LOAD`)

| Primitive | Unison | What It Does |
|-----------|--------|--------------|
| `CACH` | `Code.cache_` | Cache compiled code for later lookup |
| `LKUP` | `Code.lookup` | Look up cached code by term link |
| `LOAD` | `Code.load` | Load code from cache |

These support Unison's **distributed code model** where code is content-addressed and can be fetched/cached.

**Works in browser**: ⚠️ Different model needed.
- Native: Uses in-memory code cache
- Browser: Could use IndexedDB or fetch from server
- WASM: All code compiled ahead-of-time, so may not need dynamic lookup

### Sandboxing (`SDBL/SDBV`)

| Primitive | Unison | What It Does |
|-----------|--------|--------------|
| `SDBL` | `sandboxLinks` | Get all term links a value depends on |
| `SDBV` | `Value.validateSandboxed` | Check if value only uses allowed capabilities |

These support Unison's **capability-based security** for running untrusted code.

**Works in browser**: ⚠️ Different model.
- Native: Checks against allowed term set
- Browser/WASM: Could use Web Workers for isolation, or compile-time capability checking

---

## Quick Reference

### Where Things Live

| File | Purpose |
|------|---------|
| `ANF/POp.hs` | Primitive definitions |
| `Machine.hs` | Interpreter (semantics) |
| `Compile.hs` | WASM compilation |
| `Runtime.hs` | WASM helper functions |
| `ABI.hs` | Memory layout constants |

### Adding a Primitive Checklist

- [ ] Understand semantics from `Machine.hs`
- [ ] Add case to `compilePrimOp` in `Compile.hs`
- [ ] Add case to `builtinToPrimOp` if called as builtin
- [ ] Add runtime helper to `Runtime.hs` if needed
- [ ] Add FFI import if calling JS
- [ ] Add tests
- [ ] Update this document's status table

