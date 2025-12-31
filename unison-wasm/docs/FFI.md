# FFI: Foreign Function Interface

> How WASM calls out to the host environment (JS/Node/Browser).

## TL;DR

Unison code calls host functions via:
- **`TFOp`** — Foreign function calls (e.g., `IO.putBytes.impl.v3`)
- **`TPrm`** — Primitive operations (e.g., `TRCE` for `Debug.trace`)

We compile these to WASM imports. JS provides implementations.

```
Unison          ANF              WASM                    JS
───────────────────────────────────────────────────────────────
Debug.trace  →  TPrm TRCE  →  call $Debug_trace  →  console.log()
IO.putBytes  →  TFOp ...   →  call $IO_putBytes  →  write to stdout
```

---

## Current State (Phase 1 ✅)

### What Works

**Debug.trace / Debug.watch** are now fully implemented:

```haskell
-- Compile.hs: Debug builtins
builtinToPrimOp "Debug.trace" 2 = Just [Call "Debug_trace"]
builtinToPrimOp "Debug.watch" 2 = Just [Call "Debug_watch"]

-- Import generation: collectDebugBuiltins finds calls, debugBuiltinsToImports creates imports
```

```typescript
// ffi.ts: Unified handlers
const imports = {
  ffi: {
    Debug_trace: (textPtr, valPtr) => {
      console.log(`[trace] ${readText(memory, textPtr)}`);
      return 0n;
    },
    Debug_watch: (textPtr) => {
      console.log(`[watch] ${readText(memory, textPtr)}`);
      return textPtr;
    },
  }
};
```

**Text literals** are compiled to WASM memory:
- Allocates via `__alloc_text(byte_len)`
- Stores UTF-8 bytes inline with `i32.store8`
- Returns pointer as i64

### What's Still Needed

| Feature | Status |
|---------|--------|
| **Debug.trace/watch** | ✅ Working |
| **IO.delay** | ⏳ Phase 2 (requires async yield/resume) |
| **IO.putBytes** | ⏳ Phase 3 |
| **HTTP (fetch)** | ⏳ Phase 4 |
| **Wrong import names** | Should be `IO.putBytes.impl.v3`, `IO.delay.impl.v3` |
| **Duplicated handlers** | Same code in demo.ts and server.ts |
| **No text decoding** | Handlers receive pointers but can't read Text from memory |

---

## Real Unison FFI Surface

### Primitive Operations (TPrm)

These are built into the runtime, not foreign functions:

| Primitive | Unison | Type | Purpose |
|-----------|--------|------|---------|
| `TRCE` | `Debug.trace` | `Text -> a -> ()` | Print text, return unit |
| `PRNT` | `Debug.watch` | `Text -> a -> a` | Print text, return value |

### Foreign Functions (TFOp)

These are the actual `##`-prefixed builtins:

| ForeignFunc | Builtin Name | Type |
|-------------|--------------|------|
| `IO_putBytes_impl_v3` | `IO.putBytes.impl.v3` | `Handle -> Bytes -> {IO} ()` |
| `IO_delay_impl_v3` | `IO.delay.impl.v3` | `Nat -> {IO} ()` |
| `IO_systemTimeMicroseconds_v1` | `IO.systemTimeMicroseconds.v1` | `() -> {IO} Int` |

Source: `unison-runtime/src/Unison/Runtime/Foreign/Function/Type.hs`

---

## The Correct Design

### 1. Unified Compilation

Both `TPrm` and `TFOp` emit calls to imported functions:

```haskell
-- TPrm: Primitive operations
compileANormal ctx (TPrm TRCE [textVar, valVar]) = do
  textInstrs <- compileANormal ctx (TVar textVar)
  valInstrs <- compileANormal ctx (TVar valVar)
  pure $ textInstrs ++ valInstrs ++ [Call "Debug_trace"]

compileANormal ctx (TPrm PRNT [textVar]) = do
  textInstrs <- compileANormal ctx (TVar textVar)
  pure $ textInstrs ++ [Call "Debug_watch"]

-- TFOp: Foreign functions (already implemented)
compileANormal ctx (TFOp foreignFunc args) = do
  argInstrs <- concat <$> mapM (compileANormal ctx . TVar) args
  pure $ argInstrs ++ [Call (foreignFuncToImportName foreignFunc)]
```

### 2. Accurate Import Names

```haskell
-- Use exact Unison builtin names, with dots → underscores
foreignFuncToImportName :: ForeignFunc -> String
foreignFuncToImportName ff =
  map (\c -> if c == '.' then '_' else c) (foreignFuncBuiltinName ff)

-- Examples:
-- IO.putBytes.impl.v3  →  IO_putBytes_impl_v3
-- IO.delay.impl.v3     →  IO_delay_impl_v3
```

### 3. Unified JS Runtime

One module provides all FFI handlers:

```typescript
// unison-wasm/js/src/ffi.ts

export function createFFIHandlers(
  getMemory: () => WebAssembly.Memory
): WebAssembly.Imports {

  const readText = (ptr: bigint): string => {
    const mem = getMemory();
    const view = new DataView(mem.buffer);
    const byteLen = view.getUint32(Number(ptr) + 8, true);  // TEXT_BYTELEN_OFFSET
    const bytes = new Uint8Array(mem.buffer, Number(ptr) + 12, byteLen);
    return new TextDecoder().decode(bytes);
  };

  return {
    ffi: {
      // Primitives
      Debug_trace: (textPtr: bigint, valPtr: bigint): bigint => {
        console.log(readText(textPtr));
        return 0n; // Unit
      },
      Debug_watch: (textPtr: bigint): bigint => {
        console.log(readText(textPtr));
        return textPtr; // Return the value unchanged
      },

      // Foreign functions (real names)
      IO_putBytes_impl_v3: (handlePtr: bigint, bytesPtr: bigint): bigint => {
        // For stdout, just console.log
        const bytes = readBytes(bytesPtr);
        console.log(new TextDecoder().decode(bytes));
        return 0n;
      },
      IO_delay_impl_v3: (micros: bigint): bigint => {
        // Sync stub for now - async needs yield/resume
        const ms = Number(micros) / 1000;
        console.log(`[IO.delay] ${ms}ms (sync stub)`);
        return 0n;
      },
      IO_systemTimeMicroseconds_v1: (): bigint => {
        return BigInt(Date.now()) * 1000n;
      },
    }
  };
}
```

### 4. Demo Uses Unified Runtime

```typescript
// demo.ts
import { createFFIHandlers } from '@unison/wasm-runtime';

const wasmBytes = await fetch('pricing.wasm').then(r => r.arrayBuffer());
let memory: WebAssembly.Memory;

const imports = createFFIHandlers(() => memory);
const module = await WebAssembly.instantiate(wasmBytes, imports);
memory = module.instance.exports.memory as WebAssembly.Memory;

// Now FFI just works
const result = module.instance.exports.calculatePriceWithLog(5n);
```

---

## Sync vs Async

| Type | Pattern | Example |
|------|---------|---------|
| **Sync** | Return result immediately | `Debug.trace`, `IO.systemTime` |
| **Async** | Return `YIELD_SENTINEL`, call `resume()` later | `IO.delay`, HTTP fetch |

```typescript
// Sync: just return
Debug_trace: (textPtr, valPtr) => {
  console.log(readText(textPtr));
  return 0n;  // Done
}

// Async: yield, resume later
IO_delay_impl_v3: (micros) => {
  setTimeout(() => runtime.resume(0n), Number(micros) / 1000);
  return YIELD_SENTINEL;  // WASM yields to JS event loop
}
```

The WASM code checks the return value:
```wat
call $IO_delay_impl_v3
local.tee $result
i64.const YIELD_SENTINEL
i64.eq
if
  ;; Save continuation, return to JS
  return
end
;; Sync path: continue with result
```

---

## Implementation Plan

### Phase 1: Debug.trace (Sync) ← **Target**

1. Add `TRCE`/`PRNT` handling to `compilePrimOp`
2. Generate imports for these primitives
3. Create `unison-wasm/js/src/ffi.ts` with unified handlers
4. Update demo to use unified runtime
5. Add `Debug.trace` call to `pricing.u`

**Result:** Logs appear in browser console AND Node terminal.

### Phase 2: IO.delay (Async)

1. Implement yield/resume for async operations
2. `IO.delay` actually delays via `setTimeout`

### Phase 3: IO.putBytes (Real stdout)

1. Handle `Handle` type (stdout/stderr/file)
2. Route to appropriate output

### Phase 4: HTTP (Socket → fetch)

1. Implement socket FFI functions
2. In browser: adapt to `fetch()` API
3. Full HTTP client works in browser

---

## File Structure

```
unison-wasm/
├── src/Unison/Wasm/
│   └── Compile.hs         # TPrm TRCE/PRNT + TFOp → call imports
├── js/src/
│   ├── ffi.ts             # Unified FFI handlers (NEW)
│   ├── runtime.ts         # WASM instantiation helpers
│   └── abi-constants.ts   # Memory layout constants
└── demo/
    ├── demo.ts            # Browser: imports from ffi.ts
    └── server.ts          # Node: imports from ffi.ts
```

---

## Summary

| Before | After |
|--------|-------|
| Made-up function names | Real Unison builtin names |
| Only `TFOp` handled | Both `TFOp` and `TPrm` |
| Duplicated handlers | Unified `ffi.ts` module |
| Can't read Text from memory | `readText()` helper |
| Only sync | Sync + async (yield/resume) |

The goal: **Same Unison code with side effects runs identically in browser and server.**

