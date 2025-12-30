# WASM Backend — TODO & Reference

This document contains v1.0 requirements, future optimizations, and deferred items.

---

## v1.0 Requirements

The current implementation (v0.1.0) is a **proof of concept**. It demonstrates the architecture works but requires additional work for production use.

### What v0.1.0 Proves

| Feature | Status |
|---------|--------|
| ABI design (TypedSlot, ObjTag, TypeTag) | ✅ Tested |
| Abilities (effects) with capture/resume | ✅ E2E verified |
| Foreign calls to JavaScript | ✅ Working |
| Async yield/resume | ✅ Tested |
| Same WASM in browser + Node | ✅ Demo works |

### What's Missing for v1.0

| Item | Current State | Required |
|------|---------------|----------|
| **Browser foreign handlers** | Only `IO.printNat` | Handlers for `IO_delay`, stdout, + DOM/Events abilities |

### Browser Foreign Function Handlers

The approach: Unison already has abilities and foreign functions. We provide **browser handlers** for them, just like we did with `IO.printNat` → `console.log`.

#### Existing Unison Foreign Functions → Browser Implementations

| Unison Foreign Function | Native Implementation | Browser Handler | Status |
|-------------------------|----------------------|-----------------|--------|
| `IO.printNat` | Print to stdout | `console.log` | ✅ Done |
| `IO.printLine` | Print to stdout | `console.log` | ✅ Done |
| `IO.systemTime` | System clock | `Date.now() * 1000` | ✅ Done |
| `IO.delay` | `threadDelay` | Stub (logs only) | ⏳ Needs yield/resume |
| `IO_putBytes_impl_v3` (stdout) | Write to file handle | `console.log` | Not started |
| `IO_getLine_impl_v1` (stdin) | Read from handle | `prompt()` or custom input | Not started |
| `IO_getEnv_impl_v1` | Environment vars | Not available (or mock) | Not started |

#### Socket → Fetch Mapping (Significant Work)

Unison's HTTP is built on sockets. Browsers don't expose raw sockets.

| Unison Socket API | Browser Equivalent |
|-------------------|-------------------|
| `IO_clientSocket_impl_v3` | N/A (no raw sockets) |
| `IO_socketSend_impl_v3` | N/A |
| `IO_socketReceive_impl_v3` | N/A |

**Options:**
1. **Intercept at HTTP library level** — If Unison has an `Http.request` function, provide browser handler for that
2. **WebSocket bridge** — Connect to a server that proxies socket calls
3. **New browser-specific ability** — `Browser.fetch` ability with handler

#### New UI Abilities

These abilities have different handlers per environment:

| Ability | Browser Handler | Server Handler |
|---------|-----------------|----------------|
| `DOM` | Real DOM APIs | Virtual DOM → HTML string |
| `Events` | `addEventListener` | Server-side event simulation |
| `Storage` | `localStorage` | In-memory map or database |
| `Canvas` | Canvas 2D API | Server-side rendering (e.g., node-canvas) |

**Design principle:** Prefer handlers for existing Unison abilities. Create new abilities for features that need environment-specific implementations (like DOM), leveraging the ability system for portability.

**Example: Using existing IO ability in browser:**
```unison
-- This already works! Uses IO.printNat which we handle in browser
logPrice : Nat ->{IO} ()
logPrice price = IO.printNat price

-- Same code runs on server (prints to stdout) and browser (console.log)
```

**Example: DOM ability with environment-specific handlers:**
```unison
ability DOM where
  createElement : Text -> Element
  appendChild : Element -> Element -> ()
  setText : Element -> Text -> ()

-- Same code, different handlers:
-- Browser: creates real DOM elements
-- Server: builds vdom, can render to HTML string
renderButton : Text ->{DOM} Element
renderButton label =
  btn = DOM.createElement "button"
  DOM.setText btn label
  btn
```

---

## Future Optimizations

The MVP prioritizes correctness and debuggability over performance. These known costs should be addressed in future versions:

### Memory Representation

| MVP Choice | Cost | Future Optimization |
|------------|------|---------------------|
| 16-byte `TypedSlot` everywhere | 2× memory bandwidth | Unboxed locals for primitive-only functions |
| All constructors use `TypedSlot` fields | Large sequences | Specialized `Sequence Nat/Int/Float` |
| Always copy Text/Bytes at boundary | Encode/decode overhead | Zero-copy JS views for short-lived access |

### Continuation Capture

| MVP Choice | Cost | Future Optimization |
|------------|------|---------------------|
| Save all locals in Push frame | Large continuations | Liveness-based SavedCount |
| Flat frame layout | No hot/cold separation | Segmented frames |

### Async Handling

| MVP Choice | Cost | Future Optimization |
|------------|------|---------------------|
| No nested async | Blocks sequential fetches | Queue pending ForeignCall requests |
| Single continuation in-flight | Can't overlap I/O | Structured async regions |

### Code Generation

| MVP Choice | Cost | Future Optimization |
|------------|------|---------------------|
| WAT text → WASM binary | Slow compilation | Direct binary emission |
| No inlining | Call overhead | Inline small functions |
| No specialization | Polymorphism cost | Monomorphization for hot paths |

**Rule:** Correctness first. Don't optimize until the feature's tests pass.

---

## Appendix A: Failure Modes & Expected Errors

This table defines **what failure looks like** and **how to respond**. Tests should assert these behaviors.

| Scenario | Detection Point | Required Behavior | Test File |
|----------|-----------------|-------------------|-----------|
| Double resume | JS `ContinuationHandle.resume()` | Throw `ContinuationConsumedError` | `test-double-resume.js` |
| Nested async | WASM yield while `$async_state == 1` | Trap with `NestedAsyncError` | `test-nested-async.js` |
| Wrong TypeTag in `apply()` | JS `apply()` runtime check | Throw `TypeError` with expected/actual | `test-apply-typecheck.js` |
| Arity mismatch (under-apply) | JS `apply()` arity check | Return new PAp with additional arg | `test-partial-apply.js` |
| Arity mismatch (over-apply) | JS `apply()` arity check | Throw `ArityError` | `test-over-apply.js` |
| Invalid ObjTag | WASM decodeObject | Trap (unreachable) — ABI violation | N/A (bug) |
| Invalid TypeTag | WASM match on TypeTag | Trap (unreachable) — ABI violation | N/A (bug) |
| Null pointer dereference | Access to 0x0000-0x0FFF | Trap (memory access violation) | N/A (bug) |
| Resume with wrong continuation ID | WASM resume check | Throw `InvalidContinuationError` | `test-wrong-cont-id.js` |
| Heap exhaustion | Bump allocator overflow | Grow memory or throw `OutOfMemoryError` | `test-memory-growth.js` |

### Error Classes

```javascript
// unison-wasm/js/errors.js
export class ContinuationConsumedError extends Error {
  constructor(contId) {
    super(`Continuation ${contId} has already been consumed (exactly-once violation)`);
    this.name = 'ContinuationConsumedError';
  }
}

export class NestedAsyncError extends Error {
  constructor() {
    super('Cannot yield while another async operation is in-flight (MVP constraint)');
    this.name = 'NestedAsyncError';
  }
}

export class InvalidContinuationError extends Error {
  constructor(expected, actual) {
    super(`Expected continuation ${expected}, got ${actual}`);
    this.name = 'InvalidContinuationError';
  }
}
```

---

## Appendix B: Golden Traces

These traces show the **temporal sequence** of operations for complex scenarios.

### Golden Trace: Async fetch

```
1. WASM: Execute ForeignCall(fetch, "https://api.example.com/data")
2. WASM: Save current K at heap address 0x8120
3. WASM: Set $async_state = 1
4. WASM: Set $async_cont_id = 0x9000
5. WASM: Return YIELD_MARKER to JS
6. JS:   Receive ContinuationHandle { id: 0x9000, consumed: false }
7. JS:   Perform actual fetch()
8. JS:   ... await response ...
9. JS:   Call handle.resume(textPtr) where textPtr = 0xA100
10. JS:  Validate handle.consumed == false, set handle.consumed = true
11. JS:  Call WASM resume(0x9000, 0xA100)
12. WASM: Validate $async_cont_id == 0x9000
13. WASM: Set $async_state = 0
14. WASM: Restore K from 0x8120
15. WASM: Continue execution with result 0xA100
```

### Golden Trace: State ability (pure WASM)

```
1. WASM: THnd [State] pushes Mark frame at K
2. WASM: Mark frame stores DEnv with State handler
3. WASM: Execute body, encounter State.get
4. WASM: TShift captures K up to Mark, binds continuation to 'k'
5. WASM: Look up State.get handler in DEnv
6. WASM: Execute handler body (returns current state)
7. WASM: Resume continuation 'k' with state value
8. WASM: Pop Mark frame, continue after THnd

   [NO JS INTERACTION - entire ability runs in WASM]
```

### Golden Trace: Partial application

```
1. WASM: Evaluate (add 5) where add : Nat -> Nat -> Nat
2. WASM: Allocate PAp { combIx: add, expectedArity: 2, capturedCount: 1, args: [5] }
3. WASM: Return PAp pointer 0x7000 to caller
4. JS:   Receive closure pointer 0x7000
5. JS:   Call runtime.apply(0x7000, 10)
6. JS:   Read PAp header: expectedArity=2, capturedCount=1
7. JS:   1 + 1 == 2, so fully saturated
8. JS:   Call WASM with combIx=add, args=[5, 10]
9. WASM: Execute add(5, 10) = 15
10. JS:  Return 15n
```

---

## Deferred Items (Future Work)

The following items are not blocking the current implementation. They represent optimization opportunities or edge cases for future versions.

### Low Priority (Optimizations)

| Item | Notes |
|------|-------|
| `BX` → `I32` pointer type | Pointers compile to I64 (works, but wastes 32 bits). Future optimization. |
| TypedSlot for all boxed values | Data types use TypedSlot; function returns are I64. |
| Multi-function WASM module compilation | CLI compiles single expressions. Demo uses reference WAT. |
| Foreign call signature lookup | Look up actual signature from ForeignFunc enum instead of hardcoded. |
| Result type inference in tests | Infer result type from body expression type. |

### Low Risk (Tested Indirectly)

| Item | Notes |
|------|-------|
| TReq full E2E test | All underlying components (capture, resume, dispatch) are E2E verified. TReq generates identical patterns to TShift (fully tested). Low risk. |
| Async `fetch` E2E test | Infrastructure complete. `ContinuationHandle`, yield/resume, state machine all tested. Needs browser integration test. |

