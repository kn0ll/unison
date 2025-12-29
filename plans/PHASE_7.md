# Phase 7: Async Foreign Calls — Implementation Plan

## Overview

**Goal:** Enable Unison WASM code to call async JavaScript operations (fetch, timers, etc.) by yielding control to JS and resuming when the Promise resolves.

**MVP Constraint:** One async operation at a time (no nested async).

**Future-Proofing:** Design data structures and APIs so lifting the "one at a time" constraint requires minimal changes.

---

## Architecture

### High-Level Flow

```
Unison WASM                          JavaScript Host
─────────────                        ───────────────
1. Call async foreign func
   (e.g., IO.fetch url)
        │
        ▼
2. TFOp ForeignAsync
   - Save locals to Captured
   - Save K stack pointer
   - Store in ContinuationSlot
   - Return YIELD sentinel
        │
        ├─────────────────────────────►
        │                              3. JS receives YIELD
        │                                 - Get continuation ID
        │                                 - Call actual async func
        │                                 - .then(value => resume(id, value))
        │
        │                              4. Promise resolves
        │                                 - JS calls runtime.resume(id, value)
        ◄─────────────────────────────┤
        │
5. Resume continuation
   - Validate continuation ID
   - Restore K stack
   - Restore locals
   - Bind result value
   - Continue execution
        │
        ▼
6. Return final result
```

### Key Design Decisions

#### Decision 1: Continuations are Heap Objects (not globals)

**Why:** Enables future multi-continuation support without restructuring.

```
┌─────────────────────────────────────────────────────┐
│ OBJ_ASYNC_CONT (new heap object type)              │
├─────────────────────────────────────────────────────┤
│ Header: ObjTag(12) | Size(20) | Reserved(32)       │
│ cont_id: i64       (unique ID for JS reference)    │
│ k_ptr: i32         (saved K stack pointer)         │
│ locals_ptr: i32    (pointer to saved locals)       │
│ locals_count: i32  (number of saved locals)        │
│ status: i32        (0=pending, 1=resumed, 2=freed) │
└─────────────────────────────────────────────────────┘
```

**MVP:** Only one `OBJ_ASYNC_CONT` exists at a time (enforced at runtime).
**Future:** Multiple can coexist; remove the check.

#### Decision 2: YIELD is a Sentinel Return Value

**Why:** Allows the same export signature for sync and async functions.

```wat
;; Async foreign call returns magic sentinel
(global $YIELD_SENTINEL i64 (i64.const 0xFFFF_FFFF_FFFF_FFFE))

;; After async foreign call:
;; - If result == $YIELD_SENTINEL, caller should return immediately (propagate yield)
;; - Otherwise, result is the actual value
```

**Alternative considered:** Separate `$async_state` global checked after every call.
**Why rejected:** Sentinel is simpler and doesn't require modifying every call site.

#### Decision 3: JS API is Promise-Based

**Why:** Natural fit for async operations; extends to concurrent futures.

```typescript
class UnisonRuntime {
  // MVP: Returns Promise that resolves when computation completes
  // (may involve multiple yields internally, but caller just awaits)
  async run(funcName: string, ...args: unknown[]): Promise<unknown>;
  
  // Internal: called by async foreign functions
  yield(contId: bigint): void;
  resume(contId: bigint, value: unknown): void;
}
```

#### Decision 4: Continuation ID is a Monotonic Counter

**Why:** Simple, unique, no reuse bugs, easy to validate.

```typescript
class UnisonRuntime {
  private nextContId: bigint = 1n;
  private pendingContinuations: Map<bigint, ContinuationHandle> = new Map();
  
  allocContinuation(): bigint {
    const id = this.nextContId++;
    // ... store in map
    return id;
  }
}
```

---

## Implementation Tasks

### Task 7.1: ABI Extensions

**Add to `WASM_ABI.md`:**

```markdown
### OBJ_ASYNC_CONT (0x00B)

Represents a suspended async computation.

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0 | 8 | Header | ObjTag=0x00B, size, flags |
| 8 | 8 | cont_id | Unique continuation ID (for JS) |
| 16 | 4 | k_ptr | Saved K stack pointer |
| 20 | 4 | locals_ptr | Pointer to saved locals array |
| 24 | 4 | locals_count | Number of locals saved |
| 28 | 4 | status | 0=pending, 1=resumed, 2=freed |
| **Total** | 32 | | |
```

**Files to modify:**
- `WASM_ABI.md` — Add OBJ_ASYNC_CONT spec
- `src/Unison/Wasm/ABI.hs` — Add constants
- `js/src/abi-constants.ts` — Add JS constants

**Exit criterion:** Constants defined in both Haskell and TypeScript.

---

### Task 7.2: ContinuationHandle (JS Side)

**File:** `js/src/continuation.ts`

```typescript
export class ContinuationHandle {
  private consumed = false;
  
  constructor(
    private readonly id: bigint,
    private readonly runtime: UnisonRuntime,
  ) {}
  
  resume(value: unknown): void {
    if (this.consumed) {
      throw new ContinuationConsumedError(this.id);
    }
    this.consumed = true;
    this.runtime.resumeInternal(this.id, value);
  }
  
  // For debugging/testing
  get isConsumed(): boolean { return this.consumed; }
  get continuationId(): bigint { return this.id; }
}

export class ContinuationConsumedError extends Error {
  constructor(public readonly contId: bigint) {
    super(`Continuation ${contId} already consumed (exactly-once violation)`);
    this.name = 'ContinuationConsumedError';
  }
}
```

**Exit criterion:** 
- `ContinuationHandle` class exists with exactly-once enforcement
- Double-resume throws `ContinuationConsumedError`
- Unit tests pass

---

### Task 7.3: Async State Machine (JS Side)

**File:** `js/src/runtime.ts` (extend UnisonRuntime)

```typescript
enum AsyncState {
  Idle = 0,
  Yielded = 1,
  Resuming = 2,
}

class UnisonRuntime {
  private asyncState: AsyncState = AsyncState.Idle;
  private pendingCont: ContinuationHandle | null = null;
  private resolveRun: ((value: unknown) => void) | null = null;
  private rejectRun: ((error: Error) => void) | null = null;
  
  async run(funcName: string, ...args: unknown[]): Promise<unknown> {
    if (this.asyncState !== AsyncState.Idle) {
      throw new NestedAsyncError();
    }
    
    return new Promise((resolve, reject) => {
      this.resolveRun = resolve;
      this.rejectRun = reject;
      
      const result = this.callInternal(funcName, args);
      
      if (result === YIELD_SENTINEL) {
        // Async operation started, will resume later
        this.asyncState = AsyncState.Yielded;
      } else {
        // Sync completion
        resolve(result);
      }
    });
  }
  
  // Called by async foreign function implementations
  yield(contId: bigint): void {
    const handle = new ContinuationHandle(contId, this);
    this.pendingCont = handle;
    // Return handle to the foreign function so it can call resume
  }
  
  resumeInternal(contId: bigint, value: unknown): void {
    if (this.asyncState !== AsyncState.Yielded) {
      throw new InvalidResumeError('Not in yielded state');
    }
    
    this.asyncState = AsyncState.Resuming;
    
    // Convert value to WASM representation
    const wasmValue = this.valueToWasm(value);
    
    // Call WASM resume function
    const result = this.instance.exports.__resume(contId, wasmValue);
    
    if (result === YIELD_SENTINEL) {
      // Yielded again (sequential async)
      this.asyncState = AsyncState.Yielded;
    } else {
      // Final result
      this.asyncState = AsyncState.Idle;
      this.resolveRun!(result);
    }
  }
}
```

**Exit criterion:**
- `run()` returns Promise
- Yield/resume cycle works
- State machine prevents nested async (MVP)
- Tests for state transitions

---

### Task 7.4: WASM Yield Infrastructure

**File:** `src/Unison/Wasm/Compile.hs`

Add compilation for async foreign calls:

```haskell
-- Detect which foreign functions are async
isAsyncForeign :: ForeignFunc -> Bool
isAsyncForeign = \case
  FF_IO_fetch -> True
  FF_IO_delay -> True
  FF_IO_readFile -> True
  -- ... etc
  _ -> False

-- Compile async foreign call
compileAsyncForeignCall :: ForeignFunc -> [v] -> CompileM [WatInstr]
compileAsyncForeignCall ff args = do
  -- 1. Save current locals to heap
  saveInstrs <- compileSaveLocals
  
  -- 2. Allocate OBJ_ASYNC_CONT
  allocInstrs <- compileAllocAsyncCont
  
  -- 3. Call the foreign function (it will call runtime.yield)
  callInstrs <- compileForeignCall ff args
  
  -- 4. Return YIELD_SENTINEL
  pure $ saveInstrs ++ allocInstrs ++ callInstrs ++
    [ I64Const yieldSentinel
    , Return
    ]
```

**New WASM exports needed:**

```wat
;; Called by JS to resume a yielded computation
(func $__resume (export "__resume") (param $cont_id i64) (param $value i64) (result i64)
  ;; 1. Load OBJ_ASYNC_CONT from cont_id
  ;; 2. Validate status == pending
  ;; 3. Restore K stack from k_ptr
  ;; 4. Restore locals from locals_ptr
  ;; 5. Set status = resumed
  ;; 6. Bind $value to the awaited variable
  ;; 7. Continue execution (jump to saved PC)
)
```

**Exit criterion:**
- Async foreign calls compile to yield pattern
- `$__resume` export exists
- Locals save/restore works correctly

---

### Task 7.5: Locals Save/Restore

**Challenge:** When yielding, we must save all live locals so they can be restored on resume.

**Approach:** Reuse the `OBJ_CAPTURED` pattern from abilities (Phase 5).

```haskell
-- Save locals to heap before yielding
compileSaveLocals :: CompileM [WatInstr]
compileSaveLocals = do
  localCount <- gets csLocalCount
  -- Allocate space: 16 bytes per local (TypedSlot)
  let size = 16 * localCount
  pure $
    [ I32Const size
    , Call "$alloc"
    ] ++
    -- Store each local
    concatMap (\i -> 
      [ LocalGet (localName i)
      , LocalGet "$locals_ptr"
      , I32Const (i * 16)
      , I32Add
      , I64Store
      ]) [0..localCount-1]

-- Restore locals after resume
compileRestoreLocals :: CompileM [WatInstr]
compileRestoreLocals = do
  localCount <- gets csLocalCount
  pure $ concatMap (\i ->
    [ LocalGet "$locals_ptr"
    , I32Const (i * 16)
    , I32Add
    , I64Load
    , LocalSet (localName i)
    ]) [0..localCount-1]
```

**Exit criterion:**
- Locals survive yield/resume cycle
- Test: function with locals → yield → resume → locals correct

---

### Task 7.6: Foreign Function Registration for Async

**File:** `js/src/runtime.ts`

```typescript
interface AsyncForeignFunction {
  (runtime: UnisonRuntime, ...args: unknown[]): Promise<unknown>;
}

class UnisonRuntime {
  private asyncForeignFuncs: Map<string, AsyncForeignFunction> = new Map();
  
  registerAsyncForeign(name: string, fn: AsyncForeignFunction): void {
    this.asyncForeignFuncs.set(name, fn);
  }
  
  // Default async foreign functions
  private registerDefaults(): void {
    this.registerAsyncForeign('IO.fetch', async (runtime, url: string) => {
      const response = await fetch(url);
      return await response.text();
    });
    
    this.registerAsyncForeign('IO.delay', async (runtime, ms: number) => {
      await new Promise(resolve => setTimeout(resolve, ms));
      return null; // Unit
    });
  }
}
```

**Wiring:** When WASM calls an async foreign function:

```typescript
// In the import object passed to WebAssembly.instantiate
const imports = {
  unison: {
    'IO.fetch': (urlPtr: number) => {
      const url = runtime.getText(urlPtr);
      const contId = runtime.allocContinuation();
      
      // Start async operation
      runtime.getAsyncForeign('IO.fetch')!(runtime, url)
        .then(result => {
          runtime.getPendingCont(contId).resume(result);
        })
        .catch(err => {
          runtime.getPendingCont(contId).resumeWithError(err);
        });
      
      // Return immediately with YIELD
      runtime.yield(contId);
      return YIELD_SENTINEL;
    }
  }
};
```

**Exit criterion:**
- Async foreign functions can be registered
- `IO.fetch` and `IO.delay` work as defaults

---

### Task 7.7: Nested Async Detection (MVP Constraint)

**File:** `js/src/runtime.ts`

```typescript
class NestedAsyncError extends Error {
  constructor() {
    super(
      'Nested async operations not supported in MVP. ' +
      'Cannot start new async while one is in-flight.'
    );
    this.name = 'NestedAsyncError';
  }
}

// In async foreign function wrappers:
if (this.asyncState !== AsyncState.Idle && this.asyncState !== AsyncState.Resuming) {
  throw new NestedAsyncError();
}
```

**Future-proofing:** This is a runtime check, not a structural limitation. To enable nested async later:
1. Remove this check
2. Allow multiple entries in `pendingContinuations` map
3. Each continuation resumes independently

**Exit criterion:**
- Nested async throws `NestedAsyncError`
- Error message explains limitation
- Test verifies detection

---

### Task 7.8: Error Handling for Async

**Errors that can occur:**

| Error | When | Handling |
|-------|------|----------|
| `ContinuationConsumedError` | Double-resume | Throw in JS |
| `NestedAsyncError` | Async during async | Throw in JS |
| `InvalidContinuationError` | Resume with bad ID | Throw in JS |
| Promise rejection | Async op fails | Call `resumeWithError` |

**resumeWithError pattern:**

```typescript
class ContinuationHandle {
  resumeWithError(error: Error): void {
    if (this.consumed) {
      throw new ContinuationConsumedError(this.id);
    }
    this.consumed = true;
    this.runtime.resumeWithErrorInternal(this.id, error);
  }
}

// In runtime:
resumeWithErrorInternal(contId: bigint, error: Error): void {
  // Option 1: Propagate to run() Promise rejection
  this.rejectRun!(error);
  this.asyncState = AsyncState.Idle;
  
  // Option 2 (future): Resume with Either.Left in WASM
  // Requires ability handler support for IO errors
}
```

**Exit criterion:**
- All error types defined
- Promise rejections propagate correctly
- Tests for each error case

---

## Testing Strategy

### Unit Tests (JS)

```typescript
// js/src/tests/async.test.ts

describe('ContinuationHandle', () => {
  it('allows single resume', () => { ... });
  it('throws on double resume', () => { ... });
  it('tracks consumed state', () => { ... });
});

describe('AsyncState', () => {
  it('starts Idle', () => { ... });
  it('transitions to Yielded on async call', () => { ... });
  it('transitions to Idle on resume completion', () => { ... });
  it('throws NestedAsyncError if already yielded', () => { ... });
});
```

### Integration Tests (E2E)

```typescript
// js/src/tests/async-e2e.test.ts

describe('Async E2E', () => {
  it('fetch returns data', async () => {
    // Mock fetch
    global.fetch = async () => ({ text: async () => 'hello' });
    
    const runtime = new UnisonRuntime();
    await runtime.loadWasm(fetchPreviewModule);
    
    const result = await runtime.run('fetchPreview', 'https://example.com');
    expect(result).toBe('hello');
  });
  
  it('delay waits specified time', async () => {
    const runtime = new UnisonRuntime();
    await runtime.loadWasm(delayModule);
    
    const start = Date.now();
    await runtime.run('waitAndReturn', 100);
    const elapsed = Date.now() - start;
    
    expect(elapsed).toBeGreaterThanOrEqual(95);
  });
});
```

### Fixture Tests (Haskell → WASM → JS)

```
tests/fixtures/async/
├── fetch-simple.u      # Basic fetch
├── delay-then-return.u # Timer then value
├── fetch-chain.u       # fetch A, use result (sequential, not nested)
└── error-handling.u    # Fetch that fails
```

---

## Exit Criteria (Concrete)

### Must Pass

1. **Happy Path Test**
   ```javascript
   const result = await runtime.run('fetchText', 'https://httpbin.org/get');
   assert(result.includes('httpbin'));
   ```

2. **Double-Resume Detection**
   ```javascript
   let cont;
   runtime.onYield = c => { cont = c; };
   await runtime.run('asyncOp');
   cont.resume('first');
   assertThrows(() => cont.resume('second'), ContinuationConsumedError);
   ```

3. **Nested Async Detection**
   ```javascript
   // WASM module that tries: fetch x >>= \_ -> fetch y
   assertThrows(() => runtime.run('nestedFetch'), NestedAsyncError);
   ```

4. **Locals Preserved Across Yield**
   ```javascript
   // Unison: let x = 42; delay 10; x + 1
   const result = await runtime.run('localsTest');
   assertEqual(result, 43n);
   ```

5. **Error Propagation**
   ```javascript
   // Fetch a URL that 404s
   await assertRejects(runtime.run('fetchBad', 'https://httpbin.org/status/404'));
   ```

### Test Counts

| Category | Tests |
|----------|-------|
| ContinuationHandle unit | 5 |
| AsyncState unit | 6 |
| Integration E2E | 8 |
| Error handling | 4 |
| **Total** | 23 |

### Documentation

- [ ] `WASM_ABI.md` updated with `OBJ_ASYNC_CONT`
- [ ] `AGENTS.md` updated with Phase 7 status
- [ ] JSDoc on all new public APIs
- [ ] Error messages explain what went wrong and how to fix

---

## Future: Non-Blocking Async

The MVP has "one async at a time" but the design supports future enhancement:

### What Changes for Multi-Async

| Component | MVP | Future |
|-----------|-----|--------|
| `pendingContinuations` | Max 1 entry | Unlimited entries |
| `asyncState` | Single enum | Per-continuation state |
| Nested async check | Throws error | Allowed |
| Sequential async | Allowed (A then B) | Allowed |
| Concurrent async | Not allowed | Allowed (Promise.all) |

### Migration Path

1. Remove `NestedAsyncError` check
2. Change `asyncState` from global to per-continuation
3. Allow `run()` to be called while yielded (starts new async)
4. Add `Promise.all` equivalent for concurrent operations

### No Breaking Changes Required

The current API (`run()` returns Promise, `ContinuationHandle.resume()`) remains unchanged. Multi-async is purely additive.

---

## Implementation Order

```
Week 1: Foundation
├── Task 7.1: ABI extensions (OBJ_ASYNC_CONT)
├── Task 7.2: ContinuationHandle class
└── Task 7.3: Async state machine

Week 2: WASM Integration  
├── Task 7.4: Yield infrastructure in Compile.hs
├── Task 7.5: Locals save/restore
└── Task 7.6: Foreign function registration

Week 3: Polish & Testing
├── Task 7.7: Nested async detection
├── Task 7.8: Error handling
└── Full test suite
```

---

## Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| Phase 5 (Abilities) | ✅ Complete | Continuation capture pattern reused |
| Phase 6 (Foreign Calls) | ✅ Complete | Import/export infrastructure in place |
| `OBJ_CAPTURED` | ✅ Complete | Locals save pattern reused |
| `ForeignHandleTable` | ✅ Complete | Base for `ContinuationHandle` storage |

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Locals save/restore bugs | High | Extensive E2E tests, compare to native |
| Continuation ID reuse | Medium | Monotonic counter, never recycle |
| Memory leaks (unclaimed conts) | Medium | Add `freeContiunation()` API |
| Browser compatibility | Low | Test in Chrome, Firefox, Safari |

