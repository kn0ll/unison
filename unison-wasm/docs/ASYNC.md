# Async FFI Architecture

Unison WASM supports async foreign function calls through **delimited continuations**. When a JavaScript FFI function yields (e.g., `IO.delay`), WASM suspends, saves state, and resumes later.

---

## Overview

```
Unison                      WASM                         JavaScript
───────                     ────                         ──────────
IO.delay 1000  ────────►   call $IO_delay_impl_v3  ───►  setTimeout(1000ms)
                                                         return YIELD_SENTINEL
                           check: is YIELD_SENTINEL?
                           yes → save state, return
                                                         ...1 second later...
                           ◄── __resume(contId, 0n) ◄──  callback fires
                           restore state
                           continue execution
```

---

## Key Concepts

### YIELD_SENTINEL

A magic value (`-2n` / `0xFFFFFFFFFFFFFFFE`) that signals async yield:

```typescript
// JS returns this to indicate "I'm not done yet"
return YIELD_SENTINEL;
```

When WASM receives this value from an FFI call, it knows to suspend.

### AsyncCont Object

A heap-allocated structure storing the suspended computation's state:

| Offset | Field | Description |
|--------|-------|-------------|
| 0-7 | Header | ObjTag (0x00B) + size |
| 8-15 | cont_id | Unique ID for JS reference |
| 16-19 | k_ptr | Saved K-stack pointer |
| 20-23 | denv_ptr | Saved dynamic environment |
| 24-27 | locals_ptr | Pointer to saved locals array |
| 28-31 | locals_count | Number of saved locals |
| 32-35 | func_idx | Function table index (for call_indirect) |
| 36-39 | resume_label | Yield point ID (for br_table) |
| 40-43 | status | 0=Pending, 1=Resumed, 2=Freed, 3=Error |
| 44-47 | arity | Function arity (for call_indirect type) |

### State Machine Transformation

Functions with yield points are transformed into state machines:

```wat
(func $calculatePrice (param $p0 i64) (param $p1 i64) (result i64)
  ;; Resume dispatcher at entry
  (global.get $__async_resuming)
  (if
    (then
      ;; Restore locals from AsyncCont
      ;; Jump to saved resume point
      (br_table $state_0 $state_1 $state_2))
    (else
      ;; Normal entry: start at state 0
      (i32.const 0)
      (local.set $__state)))
  
  ;; State machine body
  (loop $state_loop
    (block $state_2
      (block $state_1
        (block $state_0
          (br_table $state_0 $state_1 $state_2 $exit)
        end) ;; state 0
        ;; Code before yield point
        (call $IO_delay_impl_v3)
        ;; Yield check: if YIELD_SENTINEL, save and return
        ...
      end) ;; state 1
      ;; Code after yield point
      ...
    end) ;; state 2
    ...
  end))
```

---

## WASM Exports

### `__resume(cont_id: i64, value: i64) -> i64`

Resume a suspended computation with a value:

1. Validates `cont_id` matches `async_cont_ptr`
2. Checks status is `Pending` (0)
3. Sets status to `Resumed` (1)
4. Loads saved state into globals
5. Sets `__async_resuming = 1`
6. Calls the suspended function via `call_indirect`

### `__resume_with_error(cont_id: i64, failure_ptr: i64) -> i64`

Resume a suspended computation with an error:

1. Same validation as `__resume`
2. Sets status to `Error` (3)
3. Wraps `failure_ptr` in `Left` constructor
4. Sets resume value to the `Left Failure` object
5. Calls the suspended function

---

## WASM Globals

```wat
(global $async_cont_id (mut i64) (i64.const 0))      ;; Counter for unique IDs
(global $async_cont_ptr (mut i32) (i32.const 0))     ;; Current AsyncCont pointer
(global $__async_resuming (mut i32) (i32.const 0))   ;; 1 if resuming
(global $__async_resume_label (mut i32) (i32.const 0)) ;; Yield point to resume
(global $__async_resume_value (mut i64) (i64.const 0)) ;; Value from JS
```

---

## JavaScript Runtime

### UnisonRuntime

```typescript
class UnisonRuntime {
  // Run a function (handles async yield/resume)
  async run(funcName: string, ...args: bigint[]): Promise<bigint>;
  
  // Register an async FFI handler
  registerAsyncForeign(
    name: string,
    handler: (rt: UnisonRuntime, ...args: bigint[]) => Promise<bigint>
  ): void;
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

### Async Foreign Handler

```typescript
runtime.registerAsyncForeign('IO.delay.impl.v3', 
  async (rt, microseconds) => {
    const ms = Number(microseconds) / 1000;
    await new Promise(r => setTimeout(r, ms));
    return 0n; // Unit
  }
);
```

The runtime:
1. Calls the handler
2. If handler returns a Promise, waits for it
3. When resolved, calls `__resume(contId, result)`

---

## Yield/Resume Flow

### Yield Path (WASM → JS)

1. FFI call returns `YIELD_SENTINEL`
2. WASM detects sentinel value
3. WASM allocates locals array on heap
4. WASM saves all locals to the array
5. WASM creates AsyncCont object with:
   - `cont_id`: unique identifier
   - `k_ptr`: current K-stack pointer
   - `denv_ptr`: current dynamic environment
   - `locals_ptr`: pointer to saved locals
   - `func_idx`: current function's table index
   - `resume_label`: yield point ID + 1
   - `arity`: function arity
6. WASM returns `YIELD_SENTINEL` to caller
7. JS runtime sets state to `Yielded`

### Resume Path (JS → WASM)

1. JS calls `runtime.resumeInternal(contId, value)`
2. `__resume` validates continuation
3. `__resume` loads state from AsyncCont
4. `__resume` sets `__async_resuming = 1`
5. `__resume` sets `__async_resume_value = value`
6. `__resume` calls function via `call_indirect`
7. Function entry detects `__async_resuming`
8. Resume dispatcher restores locals
9. `br_table` jumps to saved resume label
10. Execution continues after the yield point

---

## Error Handling

### Async Errors

When an async operation fails, JS calls `resumeWithError`:

```typescript
try {
  const result = await fetchData();
  handle.resume(result);
} catch (e) {
  handle.resumeWithError(e);
}
```

This creates a Unison `Left Failure` value on the heap.

### Exactly-Once Semantics

`ContinuationHandle` enforces single use:

```typescript
handle.resume(value);
handle.resume(value); // Throws ContinuationConsumedError
```

### Nested Async

Starting an async operation while one is already yielded throws:

```typescript
// First async yields
await runtime.run('delayedOp');
// Starting another before resume completes:
await runtime.run('anotherOp'); // Throws NestedAsyncError
```

---

## Integration with Abilities

Async yield preserves Unison's ability system:

- `k_ptr`: Saved/restored for ability handler call stack
- `denv_ptr`: Saved/restored for handler dispatch table

This ensures that after resuming from `IO.delay`, ability handlers still work correctly.

---

## Compiler Integration

### TFOp Compilation

Foreign function calls (`TFOp`) emit:

1. FFI call instruction
2. Yield sentinel check
3. If yielding: save locals, create AsyncCont, return sentinel
4. If not yielding: continue with result

### Yield Point Markers

The compiler inserts `YieldPointStart`/`YieldPointEnd` markers around FFI calls. The state machine transformation uses these to split code into segments.

### State Machine Transformation

`Unison.Wasm.Compile.Async.transformToStateMachine`:

1. Identifies yield points via markers
2. Splits function body into segments
3. Wraps in nested blocks with state variable
4. Adds resume dispatcher at entry
5. Adds `br_table` for state dispatch

---

## Performance Considerations

- **No yield overhead for sync calls**: If FFI returns immediately (not `YIELD_SENTINEL`), execution continues without state saving
- **O(1) resume dispatch**: `br_table` provides constant-time jump to resume point
- **Minimal heap allocation**: Only allocates AsyncCont when actually yielding
- **Locals saved once**: Locals array allocated on yield, not every call

---

## Alternatives Considered

### Asyncify

Emscripten's general-purpose solution that rewinds the entire WASM stack.

**Why not?** 30% code size overhead, requires post-processing, we already have ability machinery.

### JSPI (JavaScript Promise Integration)

WebAssembly proposal for automatic Promise handling.

**Why not?** Doesn't support Unison's delimited continuations. Ability handlers (`TShift`/`TKon`) require manual K-stack control that JSPI doesn't provide.

---

## See Also

- [ABI.md](./ABI.md) — Memory layout, object tags
- [FFI.md](./FFI.md) — Foreign function interface
- [Compile/Async.hs](../src/Unison/Wasm/Compile/Async.hs) — State machine transformation
- [runtime.ts](../js/src/runtime.ts) — JavaScript runtime
