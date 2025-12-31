# Unison WASM Architecture

This document is the canonical reference for the Unison WASM compiler and runtime.

---

## Table of Contents

1. [Overview](#overview)
2. [FFI Convention](#ffi-convention)
3. [Sync FFI](#sync-ffi)
4. [Async FFI](#async-ffi)
5. [Memory Layout](#memory-layout)
6. [WASM Exports](#wasm-exports)
7. [JavaScript Runtime](#javascript-runtime)
8. [Error Handling](#error-handling)
9. [Ability Integration](#ability-integration)
10. [Platform Support](#platform-support)
11. [Performance](#performance)

---

## Overview

Unison WASM compiles Unison terms to WebAssembly, enabling the same code to run in browsers and Node.js. Foreign function calls bridge WASM to JavaScript, with full support for async operations.

```
Unison Source → SuperGroup (ANF) → WAT → WASM Binary
                                     ↓
                              JavaScript Runtime
                                     ↓
                           FFI Handlers (sync/async)
```

### Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| Compiler | `src/Unison/Wasm/Compile.hs` | ANF → WAT |
| Async Transform | `src/Unison/Wasm/Compile/Async.hs` | State machine for yields |
| Runtime | `js/src/runtime.ts` | WASM loader, FFI handling |
| Continuation | `js/src/continuation.ts` | Async resume handle |
| ABI | `src/Unison/Wasm/ABI.hs` | Memory layout constants |

---

## FFI Convention

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

All FFI functions use uniform signatures:

```
(func $name (param i64)* (result i64))
```

- **Parameters**: Each Unison argument → one `i64`
- **Return**: Single `i64` (unit = `0`)
- **Boxed values**: Heap pointers in low 32 bits
- **Unboxed values**: Direct i64

---

## Sync FFI

Synchronous handlers return immediately with a value.

### Handler Interface

```typescript
interface FFIHandlers {
  [name: string]: (...args: bigint[]) => bigint | Promise<bigint>;
}
```

### Examples

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

### FFI Categories

| Category | Examples | Async |
|----------|----------|-------|
| Debug | `Debug.trace`, `Debug.watch` | No |
| IO Timing | `IO.systemTime`, `IO.delay` | delay=Yes |
| IO Random | `IO.randomBytes` | No |
| IO Handle | `IO.putBytes`, `IO.getBytes` | Possible |
| IO File | `IO.openFile`, `IO.closeFile` | Node only |

---

## Async FFI

Async operations (like `IO.delay`) yield control to JavaScript and resume later.

### YIELD_SENTINEL

A magic value signaling async yield:

```typescript
const YIELD_SENTINEL = -2n;  // 0xFFFFFFFFFFFFFFFE as signed i64
```

When an FFI handler returns `YIELD_SENTINEL`, WASM suspends execution.

### Async Call Flow

```
WASM                          JavaScript
─────                         ──────────
call $IO_delay_impl_v3  ──►   setTimeout(1000ms)
                              return YIELD_SENTINEL
                         ◄──
check: YIELD_SENTINEL?
yes → save state to heap
      return YIELD_SENTINEL
                              ...time passes...
                              callback fires
__resume(contId, 0n)    ◄──
restore state
continue execution
```

### AsyncCont Object

A heap-allocated structure storing suspended computation state:

| Offset | Field | Size | Description |
|--------|-------|------|-------------|
| 0-7 | Header | 8 | ObjTag (0x00B) + size |
| 8-15 | cont_id | 8 | Unique ID for JS reference |
| 16-19 | k_ptr | 4 | Saved K-stack pointer |
| 20-23 | denv_ptr | 4 | Saved dynamic environment |
| 24-27 | locals_ptr | 4 | Pointer to saved locals array |
| 28-31 | locals_count | 4 | Number of saved locals |
| 32-35 | func_idx | 4 | Function table index |
| 36-39 | resume_label | 4 | Yield point ID for br_table |
| 40-43 | status | 4 | 0=Pending, 1=Resumed, 2=Freed, 3=Error |
| 44-47 | arity | 4 | Function arity |

### State Machine Transformation

Functions with yield points are transformed into state machines:

```wat
(func $myFunc (param $p0 i64) (result i64)
  ;; Resume dispatcher at entry
  (global.get $__async_resuming)
  (if
    (then
      ;; Restore locals from AsyncCont
      ;; br_table to saved resume point
    )
    (else
      ;; Normal entry: state = 0
    ))
  
  ;; State machine body
  (loop $state_loop
    (block $state_2
      (block $state_1
        (block $state_0
          (br_table $state_0 $state_1 $state_2)
        end) ;; state 0: code before yield
        (call $IO_delay_impl_v3)
        ;; yield check here
      end) ;; state 1: code after yield
    end) ;; state 2: return
  end))
```

### Async Handler Example

```typescript
runtime.registerAsyncForeign('IO.delay.impl.v3', 
  async (rt, microseconds) => {
    const ms = Number(microseconds) / 1000;
    await new Promise(r => setTimeout(r, ms));
    return 0n; // Unit
  }
);
```

---

## Memory Layout

### TypedSlot (16 bytes)

Universal value representation:

```
Offset 0:  TypeTag (1 byte) + padding (7 bytes)
Offset 8:  Payload64 (8 bytes)
```

### Type Tags

| Tag | Name | Payload Interpretation |
|-----|------|------------------------|
| 0x00 | Boxed | Heap pointer (32-bit in low bits) |
| 0x01 | Nat | Unsigned 64-bit integer |
| 0x02 | Int | Signed 64-bit integer |
| 0x03 | Float | IEEE 754 double |
| 0x04 | Char | Unicode codepoint |
| 0x05 | Boolean | 0 or 1 |

### Heap Objects

| ObjTag | Name | Purpose |
|--------|------|---------|
| 0x001 | OBJ_ENUM | Nullary constructor |
| 0x002 | OBJ_DATA1 | Unary constructor |
| 0x003 | OBJ_DATA2 | Binary constructor |
| 0x004 | OBJ_DATAG | N-ary constructor |
| 0x005 | OBJ_PAP | Partial application |
| 0x006 | OBJ_CAPTURED | Captured continuation |
| 0x008 | OBJ_TEXT | UTF-8 string |
| 0x00A | OBJ_FOREIGN | Opaque JS handle |
| 0x00B | OBJ_ASYNC_CONT | Async continuation |

### Text Layout

```
Offset 0-7:   Header (ObjTag + size)
Offset 8-11:  Byte length (u32)
Offset 12-15: Char length (u32)
Offset 16+:   UTF-8 bytes
```

---

## WASM Exports

### Runtime Functions

| Export | Signature | Purpose |
|--------|-----------|---------|
| `__apply` | `(i64, i64) → i64` | Apply closure to argument |
| `__alloc_text` | `(i32) → i32` | Allocate Text with N bytes |
| `__alloc_data1` | `(i32, i32, i64) → i32` | Allocate unary constructor |
| `__alloc_datag` | `(i32, i32, i32) → i32` | Allocate N-ary constructor |
| `__resume` | `(i64, i64) → i64` | Resume suspended computation |
| `__resume_with_error` | `(i64, i64) → i64` | Resume with error |

### __resume

Resume a suspended computation with a value:

1. Validates `cont_id` matches `async_cont_ptr`
2. Checks status is `Pending` (0)
3. Sets status to `Resumed` (1)
4. Loads saved state into globals
5. Sets `__async_resuming = 1`
6. Calls suspended function via `call_indirect`

### __resume_with_error

Resume with an error (creates `Left Failure`):

1. Same validation as `__resume`
2. Sets status to `Error` (3)
3. Wraps `failure_ptr` in `Left` constructor
4. Sets resume value to `Left Failure` object
5. Calls suspended function

### WASM Globals

```wat
(global $heap_ptr (mut i32) (i32.const 16384))        ;; Heap allocation pointer
(global $k_ptr (mut i32) (i32.const 0))               ;; K-stack pointer
(global $denv_ptr (mut i32) (i32.const 0))            ;; Dynamic environment
(global $async_cont_id (mut i64) (i64.const 0))       ;; Continuation ID counter
(global $async_cont_ptr (mut i32) (i32.const 0))      ;; Current AsyncCont
(global $__async_resuming (mut i32) (i32.const 0))    ;; Resuming flag
(global $__async_resume_label (mut i32) (i32.const 0)) ;; Resume target
(global $__async_resume_value (mut i64) (i64.const 0)) ;; Resume value
```

---

## JavaScript Runtime

### UnisonRuntime

```typescript
class UnisonRuntime {
  // Load and instantiate WASM module
  async load(wasmBytes: BufferSource): Promise<void>;
  
  // Run a function (handles async yield/resume)
  async run(funcName: string, ...args: bigint[]): Promise<bigint>;
  
  // Apply a closure to arguments
  apply(closurePtr: bigint, ...args: bigint[]): bigint;
  
  // Register FFI handlers
  registerForeign(name: string, handler: FFIHandler): void;
  registerAsyncForeign(name: string, handler: AsyncFFIHandler): void;
  
  // Memory access
  allocText(text: string): number;
  readText(ptr: bigint): string;
  readDataGFields(ptr: number): bigint[];
}
```

### ContinuationHandle

Represents a suspended computation with exactly-once resumption:

```typescript
class ContinuationHandle {
  readonly id: bigint;
  
  // Resume with a value (can only call once)
  resume(value: unknown): void;
  
  // Resume with an error (can only call once)
  resumeWithError(error: Error): void;
}
```

Double-resume throws `ContinuationConsumedError`.

---

## Error Handling

### Missing Handler

If WASM calls an unimplemented FFI:

```
WebAssembly.RuntimeError: unreachable
  at $IO_openFile_impl_v3
```

### Returning Errors

Unison IO operations return `Either Failure a`. To signal an error:

```typescript
IO_openFile_impl_v3: (pathPtr, modePtr): bigint => {
  // Allocate Failure on heap
  const failurePtr = allocFailure("Not available in browser");
  // Wrap in Left constructor
  return allocLeft(failurePtr);
}
```

### Async Errors

When async operations fail, use `resumeWithError`:

```typescript
try {
  const result = await fetchData();
  handle.resume(result);
} catch (e) {
  handle.resumeWithError(e);
}
```

This creates a Unison `Left Failure` value on the heap.

### Nested Async

Starting async while another is pending throws `NestedAsyncError`:

```typescript
await runtime.run('delayedOp1');  // Yields
await runtime.run('delayedOp2');  // Throws NestedAsyncError
```

---

## Ability Integration

Async yield preserves Unison's ability system:

- **`k_ptr`**: Saved/restored for ability handler call stack
- **`denv_ptr`**: Saved/restored for handler dispatch table

This ensures ability handlers work correctly after resuming from `IO.delay`.

---

## Platform Support

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

## Performance

### Async Overhead

- **No overhead for sync calls**: If FFI returns immediately, no state saving
- **O(1) resume dispatch**: `br_table` provides constant-time jump
- **Minimal heap allocation**: Only allocates AsyncCont when yielding
- **Locals saved once**: Array allocated on yield, not every call

### Alternatives Considered

**Asyncify**: Emscripten's general solution that rewinds entire WASM stack.
- Rejected: 30% code size overhead, requires post-processing

**JSPI**: WebAssembly Promise Integration proposal.
- Rejected: Doesn't support Unison's delimited continuations. Ability handlers require manual K-stack control.

---

## See Also

- [ABI.md](./ABI.md) — Memory layout details
- [PRIMITIVES.md](./PRIMITIVES.md) — Unison primitives implementation
- [MAPS.md](./MAPS.md) — Map support strategy
- [TODO.md](./TODO.md) — Known limitations, future work

