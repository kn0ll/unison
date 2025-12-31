# Async FFI — Design & Implementation Strategy

**Version:** 0.1.0 (Draft)
**Status:** Planning

This document defines the strategy for implementing true async/await semantics for Unison WASM FFI calls. It covers the current state, target design, implementation phases, and strict exit criteria.

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Current State](#current-state)
3. [Target Design](#target-design)
4. [Implementation Phases](#implementation-phases)
5. [Appendices](#appendices)

---

## Executive Summary

### The Problem

Unison WASM can call JavaScript FFI functions, but cannot **yield** and **resume** for async operations. When `IO.delay` calls `setTimeout`, WASM continues executing immediately instead of waiting.

### The Root Cause

The Haskell compiler emits a simple `Call` instruction for `TFOp`:

```wat
call $IO_delay_impl_v3    ;; FFI returns YIELD_SENTINEL (0xFFFFFFFFFFFFFFFE)
local.set $p5             ;; ← WASM stores it as normal value and continues!
call $Debug_trace         ;; ← Executes immediately, doesn't wait
```

The compiler must instead:
1. Check if the return value is `YIELD_SENTINEL`
2. If yes: save locals, return `YIELD_SENTINEL` to propagate yield
3. If no: continue normal execution
4. Provide a resume point for `__resume` to jump to

### The Solution

Implement **delimited continuations at the WASM level** for async FFI calls. This mirrors how `TShift`/`TKon` handle Unison abilities, but integrated with the JavaScript event loop.

---

## Current State

### What Works ✅

| Component | Status | Evidence |
|-----------|--------|----------|
| Sync FFI calls | ✅ Working | `Debug.trace` logs in browser/Node |
| FFI import generation | ✅ Working | Compiler emits `(import "ffi" ...)` |
| Yield sentinel constant | ✅ Defined | `YIELD_SENTINEL = 0xFFFFFFFFFFFFFFFE` |
| `AsyncState` enum | ✅ Implemented | `Idle`, `Yielded`, `Resuming` |
| `ContinuationHandle` class | ✅ Implemented | Exactly-once enforcement |
| `__resume` export | ✅ Stub exists | Validates cont_id, returns value |
| `__alloc_async_cont` | ✅ Implemented | Allocates 32-byte AsyncCont object |
| Nested async guard | ✅ Implemented | `NestedAsyncError` thrown |

### What's Broken ❌

| Component | Status | Issue |
|-----------|--------|-------|
| Yield checking | ❌ Missing | Compiler doesn't check return value |
| Local saving | ❌ Missing | No code to save locals on yield |
| Resume labels | ❌ Missing | No way to resume mid-function |
| K-stack integration | ❌ Missing | Async yield doesn't push K frame |
| `__resume` body | ❌ Stub only | Doesn't restore state or jump |

### Current Code Path

```
Unison Code           Compiler                    WASM                    JS
───────────           ─────────                   ────                    ──
IO.delay 1000   →     TFOp ForeignDelay args  →   call $IO_delay   →   setTimeout(...)
                                                                         return YIELD_SENTINEL
                                                  local.set $result   ← (stored as i64!)
                                                  ;; continues immediately!
```

### Why This Happens

In `Compile.hs`:

```haskell
compileANormal ctx (TFOp foreignFunc args) = do
  argInstrs <- concat <$> mapM (compileANormal ctx . TVar) args
  let funcName = foreignFuncToImportName foreignFunc
  pure $ argInstrs ++ [Call funcName]  -- ← Just calls and continues!
```

Compare to `TShift` which does capture locals and walk the K-stack.

---

## Target Design

### Design Principles

1. **Reuse ability machinery**: Async yield/resume should use the same K-stack and Captured objects as `TShift`/`TKon`
2. **Minimize magic**: No hidden state machines in WASM—all state is explicit in AsyncCont and K
3. **Single mechanism**: All FFI calls (sync and async) use the same code path; sync is just async with immediate resume
4. **Fail-fast**: Invalid states cause immediate traps, not silent corruption

### Target Code Path

```
Unison Code           Compiler                    WASM                    JS
───────────           ─────────                   ────                    ──
IO.delay 1000   →     TFOp ForeignDelay args  →   call $IO_delay   →   setTimeout(...)
                                                                         return YIELD_SENTINEL
                                                  ;; YIELD CHECK:
                                                  local.tee $result
                                                  i64.const YIELD_SENTINEL
                                                  i64.eq
                                                  if
                                                    ;; Save all locals to AsyncCont
                                                    call $__save_async_state
                                                    ;; Record resume label
                                                    i32.const LABEL_42
                                                    global.set $async_resume_label
                                                    ;; Propagate yield
                                                    i64.const YIELD_SENTINEL
                                                    return
                                                  end
                                              ◄── LABEL_42: (resume point)
                                                  ;; Continue with $result
                                                  ...

                                                                   ...timeout fires...

                                              ◄── call $__resume(cont_id, value)
                                                  ;; Restore locals from AsyncCont
                                                  call $__restore_async_state
                                                  ;; Jump to resume label
                                                  global.get $async_resume_label
                                                  br_table [LABEL_42, ...]
```

### Async Protocol (Detailed)

#### Step 1: FFI Call + Yield Check

After every potentially-async FFI call, emit:

```wat
(local.tee $__ffi_result)
(i64.const 0xFFFFFFFFFFFFFFFE)  ;; YIELD_SENTINEL
(i64.eq)
(if
  ;; === YIELD PATH ===
  (then
    ;; 1. Save locals count
    (i32.const <num_locals>)
    (global.set $__async_locals_count)

    ;; 2. Save each local to linear memory
    (global.get $__async_locals_ptr)
    (local.get $p0)
    (i64.store offset=0)
    ;; ... repeat for all locals ...

    ;; 3. Save K stack pointer
    (global.get $k_ptr)
    (global.set $__async_k_ptr)

    ;; 4. Set resume label (unique per yield point)
    (i32.const YIELD_POINT_ID)
    (global.set $__async_resume_label)

    ;; 5. Return YIELD_SENTINEL to caller
    (i64.const 0xFFFFFFFFFFFFFFFE)
    (return))
  ;; === NORMAL PATH ===
  (else
    ;; Continue with result in $__ffi_result
    (nop)))
```

#### Step 2: Resume Entry Point

Each function with yield points needs a resume dispatcher at the top:

```wat
(func $fn_with_async (param ...) (result i64)
  ;; Check if this is a resume call
  (global.get $__async_resuming)
  (if (result i64)
    (then
      ;; Clear resuming flag
      (i32.const 0)
      (global.set $__async_resuming)

      ;; Restore all locals from saved state
      (global.get $__async_locals_ptr)
      (i64.load offset=0)
      (local.set $p0)
      ;; ... repeat for all locals ...

      ;; Restore K
      (global.get $__async_k_ptr)
      (global.set $k_ptr)

      ;; Jump to correct resume point
      (global.get $__async_resume_label)
      (br_table $yield_0 $yield_1 $yield_2 ...))
    (else
      ;; Normal entry - fall through
      (nop)))

  ;; ... normal function body with yield points ...

  ;; Resume labels are block/loop targets
  (block $yield_0
    (block $yield_1
      ;; Function body
      (call $IO_delay_impl_v3)
      ;; Yield check after call
      ;; If not yielding, continue
      ;; If yielding, resume label = 0
      ...
    ) ;; end $yield_1
    ;; Code after yield point 1
  ) ;; end $yield_0
)
```

### Data Structures

#### AsyncCont Object (on heap)

```
┌────────────────────────────────────────┐
│ Header (64 bits) - ObjTag=0x00B        │  ← bytes 0-7
├────────────────────────────────────────┤
│ ContId (64 bits)                       │  ← bytes 8-15
├────────────────────────────────────────┤
│ KPtr (32) │ ResumeLabel (32)           │  ← bytes 16-23
├────────────────────────────────────────┤
│ LocalsCount (32) │ Status (32)         │  ← bytes 24-31
├────────────────────────────────────────┤
│ FuncRef (32) │ Reserved (32)           │  ← bytes 32-39  [NEW]
├────────────────────────────────────────┤
│ Locals[0..N-1] (64 bits each)          │  ← bytes 40+
└────────────────────────────────────────┘
```

| Field | Description |
|-------|-------------|
| `ContId` | Unique ID for JS-side `ContinuationHandle` |
| `KPtr` | Saved K stack pointer |
| `ResumeLabel` | Which yield point to resume (index into br_table) |
| `LocalsCount` | Number of saved locals |
| `Status` | `0=Pending`, `1=Resumed`, `2=Freed` |
| `FuncRef` | Table index of the suspended function |
| `Locals[]` | Saved local variables |

#### Global Variables

```wat
;; Existing
(global $async_cont_id (mut i64) (i64.const 0))
(global $async_cont_ptr (mut i32) (i32.const 0))

;; New
(global $__async_resuming (mut i32) (i32.const 0))     ;; 1 if entering via resume
(global $__async_resume_label (mut i32) (i32.const 0)) ;; Which yield point
(global $__async_locals_ptr (mut i32) (i32.const 0))   ;; Pointer to locals array
(global $__async_locals_count (mut i32) (i32.const 0)) ;; How many locals saved
(global $__async_k_ptr (mut i32) (i32.const 0))        ;; Saved K
(global $__async_func_idx (mut i32) (i32.const 0))     ;; Suspended function
```

### `__resume` Implementation

```wat
(func $__resume (param $cont_id i64) (param $value i64) (result i64)
  (local $cont_ptr i32)
  (local $func_idx i32)

  ;; 1. Validate continuation ID
  (global.get $async_cont_ptr)
  (local.set $cont_ptr)

  (local.get $cont_ptr)
  (i64.load offset=8)  ;; Load stored cont_id
  (local.get $cont_id)
  (i64.ne)
  (if (then (unreachable)))  ;; Invalid continuation

  ;; 2. Check status is Pending (0)
  (local.get $cont_ptr)
  (i32.load offset=28)
  (if (then (unreachable)))  ;; Already resumed/freed

  ;; 3. Mark as Resumed
  (local.get $cont_ptr)
  (i32.const 1)
  (i32.store offset=28)

  ;; 4. Load saved state into globals
  (local.get $cont_ptr)
  (i32.load offset=16)
  (global.set $__async_k_ptr)

  (local.get $cont_ptr)
  (i32.load offset=20)
  (global.set $__async_resume_label)

  (local.get $cont_ptr)
  (i32.load offset=24)
  (global.set $__async_locals_count)

  (local.get $cont_ptr)
  (i32.const 40)  ;; offset of Locals array
  (i32.add)
  (global.set $__async_locals_ptr)

  ;; 5. Set resuming flag
  (i32.const 1)
  (global.set $__async_resuming)

  ;; 6. Load function index and call via indirect
  (local.get $cont_ptr)
  (i32.load offset=32)
  (local.set $func_idx)

  ;; 7. Store the resume value somewhere accessible
  (local.get $value)
  (global.set $__async_resume_value)

  ;; 8. Call the suspended function (via table)
  (local.get $func_idx)
  (call_indirect (result i64))
)
```

---

## Implementation Phases

### Phase 1: Yield Point Infrastructure

**Goal:** Compiler emits yield-checking code after FFI calls.

**Tasks:**
1. Add `YieldPointId` counter to `CompileCtx`
2. Modify `compileANormal` for `TFOp` to emit yield check
3. Add globals: `__async_resuming`, `__async_resume_label`
4. Track which functions have yield points

**Exit Criteria:**
- [ ] WASM checks return value after FFI call
- [ ] `YIELD_SENTINEL` causes `return YIELD_SENTINEL`
- [ ] Sync FFI (`Debug.trace`) still works
- [ ] Unit test: `test-yield-check.js` passes

---

### Phase 2: Local State Saving

**Goal:** Save all locals when yielding.

**Tasks:**
1. Count locals at each yield point (`getSaveableLocalCount`)
2. Allocate locals array in AsyncCont (dynamic size)
3. Emit local-saving code before `return YIELD_SENTINEL`
4. Store func_idx and resume_label in AsyncCont

**Exit Criteria:**
- [ ] Locals saved to heap on yield
- [ ] AsyncCont object created with correct data
- [ ] JS can read saved locals
- [ ] Unit test: `test-local-saving.js` passes

---

### Phase 3: Resume Dispatch

**Goal:** `__resume` can re-enter a function at the correct point.

**Tasks:**
1. Emit resume dispatcher at function entry
2. Generate `br_table` for resume labels
3. Emit local-restoring code
4. Call suspended function via `call_indirect`

**Exit Criteria:**
- [ ] `__resume` restores locals
- [ ] `__resume` jumps to correct yield point
- [ ] Computation continues after resume
- [ ] E2E test: `IO.delay 1000` takes ~1 second

---

### Phase 4: K-Stack Integration

**Goal:** Async yield interacts correctly with Unison abilities.

**Tasks:**
1. Save K-stack pointer in AsyncCont
2. Restore K-stack on resume
3. Handle case where yield happens inside a handler scope
4. Test nested handler + async

**Exit Criteria:**
- [ ] K-stack saved/restored across async
- [ ] Ability handlers work with async
- [ ] Nested handlers don't corrupt state
- [ ] E2E test: `State` handler + `IO.delay`

---

### Phase 5: Error Handling

**Goal:** Async failures propagate correctly.

**Tasks:**
1. `resumeWithError` returns `Left Failure`
2. Async timeout/cancellation
3. Cleanup on error

**Exit Criteria:**
- [ ] Async errors become `Failure` values
- [ ] Double-resume throws `ContinuationConsumedError`
- [ ] Nested async throws `NestedAsyncError`
- [ ] E2E test: Error propagation

---

### Full Feature Complete

All phases done. Final verification:

- [ ] All phase exit criteria met
- [ ] Browser demo: pricing with `IO.delay` works
- [ ] Node demo: same code works
- [ ] Golden traces updated
- [ ] TODO.md updated to show feature complete
- [ ] FFI.md updated to remove "async missing" note

---

## Appendices

### A. Comparison: TShift vs Async Yield

| Aspect | TShift (Abilities) | Async Yield (FFI) |
|--------|-------------------|-------------------|
| Trigger | `TShift abilityRef contVar body` | `TFOp` returns `YIELD_SENTINEL` |
| K capture | Walk K to Mark, create Captured | Save K-ptr in AsyncCont |
| Locals | Save to Captured slots | Save to AsyncCont slots |
| Resume | `TKon` with continuation | JS calls `__resume` |
| Resume point | Handler body | `br_table` to yield label |

### B. Alternative: Asyncify

Emscripten's Asyncify is a general-purpose solution that:
1. Rewinds the entire WASM call stack
2. Saves all state to linear memory
3. Resumes by re-calling from the top

**Why not Asyncify?**
- Requires post-processing of WASM binary
- Significant code size overhead (~30%)
- Slower than targeted yield points
- We already have ability machinery that's similar

### C. Alternative: JSPI (JavaScript Promise Integration)

JSPI is a WebAssembly proposal that:
1. Allows WASM imports to return Promises
2. Automatically suspends WASM on Promise await
3. Resumes when Promise resolves

**Why not JSPI?**
- Not yet standardized (Stage 2 as of 2024)
- Not available in all browsers
- We need cross-platform solution now

### D. Memory Layout for Locals

When saving N locals:

```
AsyncCont + 40:  local[0] (i64)
AsyncCont + 48:  local[1] (i64)
...
AsyncCont + 40 + 8*(N-1): local[N-1] (i64)
```

Total AsyncCont size: `40 + 8*N` bytes

### E. Golden Trace: Async IO.delay

```
1.  WASM: TFOp(IO.delay.impl.v3, [1000000])
2.  WASM: call $IO_delay_impl_v3
3.  JS:   Handler called with args [1000000n]
4.  JS:   Allocate contId = 1, setTimeout(1000ms)
5.  JS:   Return YIELD_SENTINEL to WASM
6.  WASM: Compare result with YIELD_SENTINEL → equal
7.  WASM: Save locals[0..4] to heap @ 0x8100
8.  WASM: Save k_ptr to global $__async_k_ptr
9.  WASM: Set resume_label = 0
10. WASM: Return YIELD_SENTINEL
11. JS:   run() receives YIELD_SENTINEL
12. JS:   Set asyncState = Yielded
13. JS:   (wait 1000ms)
14. JS:   setTimeout callback fires
15. JS:   handle.resume(0n) called
16. JS:   __resume(1, 0n) called
17. WASM: Validate cont_id == 1 ✓
18. WASM: Mark status = Resumed
19. WASM: Load locals from 0x8100
20. WASM: Set __async_resuming = 1
21. WASM: call_indirect(func_idx)
22. WASM: Function entry: __async_resuming == 1
23. WASM: Restore locals from globals
24. WASM: br_table → $yield_0
25. WASM: Continue after delay call
26. WASM: Return final result
27. JS:   Result received, resolve Promise
```

---

## References

- [ABI.md](./ABI.md) — Memory layout, ObjTag definitions
- [FFI.md](./FFI.md) — FFI protocol, handler interface
- [TODO.md](./TODO.md) — Known limitations, future work
- [Compile.hs](../src/Unison/Wasm/Compile.hs) — Current TFOp compilation
- [runtime.ts](../js/src/runtime.ts) — JS runtime with async infrastructure
- [continuation.ts](../js/src/continuation.ts) — ContinuationHandle class

