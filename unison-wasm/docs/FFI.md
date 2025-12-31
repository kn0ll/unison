# FFI Specification

**Version:** 0.1.0

This document defines the Foreign Function Interface for Unison WASM modules. It specifies how compiled WASM calls out to host environments (JavaScript in browser or Node.js).

---

## Implementation Status

### v0.1.0 (Current)

| Feature | Status | Notes |
|---------|--------|-------|
| Sync FFI calls | ✅ Working | `Debug.trace`, `Debug.watch` |
| Import generation | ✅ Working | Compiler emits `(import "ffi" ...)` |
| Text reading | ✅ Working | `readText()` helper |
| `##` builtin FFI | ✅ Working | `##IO.delay.impl.v3` compiled correctly |
| Cross-function calls | ✅ Working | Multi-entry compilation fixed |
| Async JS infrastructure | ✅ Built | Yield/resume protocol, `ContinuationHandle` |
| **Async compiler support** | ❌ Missing | See note below |
| UnisonRuntime in demo | ✅ Working | Proper FFI handler registration |

> **Note on Async FFI:** The JS runtime infrastructure is ready (yield sentinel,
> `__resume`, continuation handles), but the **compiler doesn't yet generate
> yield-checking code** after `TFOp` calls. WASM currently treats `YIELD_SENTINEL`
> as a normal return value and continues executing. See `TODO.md` for details.

### v0.2.0 (Planned)

| Feature | Status | Notes |
|---------|--------|-------|
| `IO.delay` async | ⏳ | Currently sync stub, async ready |
| `IO.systemTime` | ⏳ | Sync, trivial |
| `IO.randomBytes` | ⏳ | Sync, use `crypto.getRandomValues` |
| Bytes reading/writing | ⏳ | Similar to Text |

### Future

| Feature | Notes |
|---------|-------|
| Nested async | Currently: error if yield while yield pending |
| Multiple continuations | Currently: single in-flight continuation |
| Full IO.* coverage | ~40 FFI functions for complete IO support |
| HTTP | Socket emulation or `fetch` adapter |

### MVP Constraints

The current async implementation has intentional limitations:

1. **No nested async**: Calling an async FFI while another is pending throws `NestedAsyncError`
2. **Single continuation**: Only one continuation can be in-flight at a time
3. **No overlapping I/O**: Sequential async calls must complete before next begins

These constraints simplify the implementation while covering common use cases.

---

## Design Principles

1. **Exact names**: Import names match Unison builtin names (with `.` → `_` substitution)
2. **Uniform signatures**: All FFI functions use i64 for parameters and returns
3. **Namespace separation**: FFI imports use the `"ffi"` module namespace
4. **Platform agnostic**: Same WASM binary works in browser and Node.js
5. **Fail-fast**: Missing handlers cause immediate runtime errors, not silent failures

---

## Import Convention

### Module Namespace

All FFI imports use the `"ffi"` namespace:

```wat
(import "ffi" "Debug_trace" (func $Debug_trace (param i64 i64) (result i64)))
(import "ffi" "IO_delay_impl_v3" (func $IO_delay_impl_v3 (param i64) (result i64)))
```

### Name Mapping

| Unison Builtin | WASM Import Name | Rule |
|----------------|------------------|------|
| `Debug.trace` | `Debug_trace` | Replace `.` with `_` |
| `IO.delay.impl.v3` | `IO_delay_impl_v3` | Replace `.` with `_` |
| `IO.putBytes.impl.v3` | `IO_putBytes_impl_v3` | Replace `.` with `_` |

### Signature Convention

All FFI functions follow this pattern:

```
(func $name (param i64)* (result i64))
```

- **Parameters**: Each Unison argument becomes one `i64` parameter
- **Return**: Single `i64` result (or unit represented as `0`)
- **Boxed values**: Passed as heap pointers (in low 32 bits of i64)
- **Unboxed values**: Passed directly as i64

---

## FFI Categories

### Category 1: Debug Primitives

Synchronous logging operations. Return immediately.

| Import | Signature | Semantics |
|--------|-----------|-----------|
| `Debug_trace` | `(i64, i64) → i64` | Log text, return `0` (unit) |
| `Debug_watch` | `(i64, i64) → i64` | Log text, return second arg unchanged |

**First argument**: Pointer to Text object (see ABI.md for Text layout)
**Second argument**: Value being traced (opaque, for watch: returned)

### Category 2: IO Operations

May be synchronous or asynchronous.

| Import | Signature | Sync/Async | Semantics |
|--------|-----------|------------|-----------|
| `IO_systemTime_impl_v3` | `() → i64` | Sync | Return microseconds since epoch |
| `IO_delay_impl_v3` | `(i64) → i64` | **Async** | Delay for N microseconds |
| `IO_randomBytes_impl_v1` | `(i64) → i64` | Sync | Generate N random bytes → Bytes ptr |

### Category 3: IO Handle Operations

File/stream operations. Most are **not available in browser**.

| Import | Signature | Browser | Node |
|--------|-----------|---------|------|
| `IO_putBytes_impl_v3` | `(i64, i64) → i64` | Console only | ✅ |
| `IO_getBytes_impl_v3` | `(i64, i64) → i64` | ❌ | ✅ |
| `IO_openFile_impl_v3` | `(i64, i64) → i64` | ❌ | ✅ |

---

## Async FFI Protocol

Some operations (like `IO.delay`) cannot complete synchronously. These use the **yield/resume** protocol.

### Yield Sentinel

When an async FFI call cannot complete immediately, it returns the **yield sentinel**:

```
YIELD_SENTINEL = 0xFFFF_FFFF_FFFF_FFFE
```

This value is chosen to be invalid as a pointer, Nat, or normal return value.

### Async Call Flow

```
WASM                          JS Runtime
─────                         ──────────
call $IO_delay_impl_v3  ──►
                              Check: can complete sync?
                              No → save continuation
                         ◄──  return YIELD_SENTINEL

(function returns YIELD_SENTINEL to JS)

                              setTimeout(resume, delay)

                              ... time passes ...

call $__resume(cont_id, result) ◄── Resume with result
                         ──►  Return result to WASM
(computation continues)
```

### Continuation State

When yielding, JS must save:

| Field | Type | Description |
|-------|------|-------------|
| `cont_id` | `i64` | Unique continuation identifier |
| `k_ptr` | `i32` | Saved K stack pointer |
| `locals_ptr` | `i32` | Pointer to saved locals array |
| `locals_count` | `i32` | Number of saved locals |

See `OBJ_ASYNC_CONT` in ABI.md for the heap layout.

---

## Implementing FFI Handlers

### JavaScript Handler Interface

Handlers receive WASM memory and can read/write heap objects:

```typescript
interface FFIHandlers {
  [name: string]: (...args: bigint[]) => bigint | Promise<bigint>;
}
```

### Sync Handler Example

```typescript
const handlers: FFIHandlers = {
  Debug_trace: (textPtr: bigint, valPtr: bigint): bigint => {
    const text = readText(memory, textPtr);
    console.log(`[trace] ${text}`);
    return 0n;  // Unit
  },

  IO_systemTime_impl_v3: (): bigint => {
    return BigInt(Date.now()) * 1000n;  // Microseconds
  },
};
```

### Async Handler Example

```typescript
const handlers: FFIHandlers = {
  IO_delay_impl_v3: (microseconds: bigint): bigint => {
    const contId = saveCurrentContinuation();
    const ms = Number(microseconds) / 1000;

    setTimeout(() => {
      resumeContinuation(contId, 0n);  // Resume with unit
    }, ms);

    return YIELD_SENTINEL;
  },
};
```

### Instantiation

```typescript
const imports: WebAssembly.Imports = {
  ffi: handlers,
};

const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
```

---

## Reading Heap Objects

FFI handlers often need to read Unison values from WASM memory.

### Text

Layout (see ABI.md):
```
Offset 0-7:   Header
Offset 8-11:  Byte length (u32)
Offset 12-15: Char length (u32)
Offset 16+:   UTF-8 bytes
```

```typescript
function readText(memory: WebAssembly.Memory, ptr: bigint): string {
  const view = new DataView(memory.buffer);
  const ptrNum = Number(ptr);
  const byteLen = view.getUint32(ptrNum + 8, true);
  const bytes = new Uint8Array(memory.buffer, ptrNum + 16, byteLen);
  return new TextDecoder().decode(bytes);
}
```

### Bytes

Layout:
```
Offset 0-7:   Header
Offset 8-11:  Byte length (u32)
Offset 16+:   Raw bytes
```

```typescript
function readBytes(memory: WebAssembly.Memory, ptr: bigint): Uint8Array {
  const view = new DataView(memory.buffer);
  const ptrNum = Number(ptr);
  const len = view.getUint32(ptrNum + 8, true);
  return new Uint8Array(memory.buffer, ptrNum + 16, len);
}
```

### Unboxed Values

Nat, Int, Float, Char are passed directly as i64:

```typescript
function toNat(value: bigint): number {
  return Number(value);
}

function toFloat(value: bigint): number {
  const buffer = new ArrayBuffer(8);
  new BigInt64Array(buffer)[0] = value;
  return new Float64Array(buffer)[0];
}
```

---

## Writing Heap Objects

To return heap-allocated values, use WASM's exported allocators.

### Allocating Text

```typescript
async function allocText(instance: WebAssembly.Instance, text: string): Promise<bigint> {
  const bytes = new TextEncoder().encode(text);
  const ptr = (instance.exports.__alloc_text as Function)(bytes.length);

  const memory = instance.exports.memory as WebAssembly.Memory;
  const dest = new Uint8Array(memory.buffer, ptr + 16, bytes.length);
  dest.set(bytes);

  return BigInt(ptr);
}
```

### Exported Allocators

| Export | Signature | Purpose |
|--------|-----------|---------|
| `__alloc_text` | `(i32) → i32` | Allocate Text with N bytes capacity |
| `__alloc_data1` | `(i32, i32, i64) → i32` | Allocate Data1 constructor |
| `__alloc_datag` | `(i32, i32, i32) → i32` | Allocate DataG constructor |

---

## Error Handling

### Missing Handler

If WASM calls an import that isn't provided:

```
WebAssembly.RuntimeError: unreachable
  at $IO_openFile_impl_v3
```

Handlers should be provided for all imports the WASM module declares.

### Returning Errors

Unison IO operations return `Either Failure a`. To signal an error:

1. Allocate a `Failure` object on the heap
2. Wrap in `Left` constructor
3. Return pointer

```typescript
IO_openFile_impl_v3: (pathPtr: bigint, modePtr: bigint): bigint => {
  // Browser can't open files
  return allocLeft(allocFailure("Not available in browser"));
}
```

---

## Platform Support Matrix

| FFI Function | Browser | Node.js | Notes |
|--------------|---------|---------|-------|
| `Debug_trace` | ✅ | ✅ | `console.log` |
| `Debug_watch` | ✅ | ✅ | `console.log` |
| `IO_systemTime_impl_v3` | ✅ | ✅ | `Date.now()` |
| `IO_delay_impl_v3` | ✅ | ✅ | `setTimeout` (async) |
| `IO_randomBytes_impl_v1` | ✅ | ✅ | `crypto.getRandomValues` |
| `IO_putBytes_impl_v3` | ⚠️ | ✅ | Browser: console only |
| `IO_getBytes_impl_v3` | ❌ | ✅ | No stdin in browser |
| `IO_openFile_impl_v3` | ❌ | ✅ | No filesystem in browser |
| `IO_clientSocket_impl_v3` | ❌ | ✅ | No raw sockets in browser |

---

## Reference Implementation

The canonical FFI handler implementation is in:

```
unison-wasm/js/src/ffi.ts
```

This module provides:
- `createFFIHandlers(getMemory)` — Creates standard handlers
- `readText(memory, ptr)` — Read Text from heap
- `mergeHandlers(...handlers)` — Combine handler sets

---

## Version History

| Version | Changes |
|---------|---------|
| 0.1.0 | Initial specification. Debug.trace/watch implemented. |
