# WASM Backend — TODO & Reference

---

## What's Missing for v1.0

| Item | Current State | Required |
|------|---------------|----------|
| More IO builtins | `Debug.trace`, `IO.delay` | Full `IO.*` coverage |
| HTTP in browser | No raw sockets | Fetch adapter or ability |

### FFI: Next Phase

| Task | Description | Status |
|------|-------------|--------|
| `IO.putBytes.impl.v3` | `console.log` / stdout (sync) | ⏳ Easy |
| `IO.randomBytes.impl.v1` | `crypto.getRandomValues` | ⏳ Easy |
| HTTP via sockets | Complex — see below | ⏳ Future |

### Socket → Fetch Mapping

Unison's HTTP is built on sockets. Browsers don't expose raw sockets.

| Unison Socket API | Browser Equivalent |
|-------------------|-------------------|
| `IO_clientSocket_impl_v3` | N/A (no raw sockets) |
| `IO_socketSend_impl_v3` | N/A |
| `IO_socketReceive_impl_v3` | N/A |

**Options:**
1. **Intercept at HTTP library level** — If Unison has an `Http.request` function, provide browser handler
2. **WebSocket bridge** — Connect to a server that proxies socket calls
3. **New browser-specific ability** — `Browser.fetch` ability with handler

### New UI Abilities

| Ability | Browser Handler | Server Handler |
|---------|-----------------|----------------|
| `DOM` | Real DOM APIs | Virtual DOM → HTML string |
| `Events` | `addEventListener` | Server-side event simulation |
| `Storage` | `localStorage` | In-memory map or database |
| `Canvas` | Canvas 2D API | Server-side rendering |

**Design principle:** Prefer handlers for existing Unison abilities. Create new abilities for features that need environment-specific implementations.

---

## Future Optimizations

The MVP prioritizes correctness over performance.

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

---

## Appendix A: Failure Modes

| Scenario | Detection Point | Required Behavior |
|----------|-----------------|-------------------|
| Double resume | `ContinuationHandle.resume()` | Throw `ContinuationConsumedError` |
| Nested async | WASM yield while pending | Throw `NestedAsyncError` |
| Wrong TypeTag in `apply()` | JS runtime check | Throw `TypeError` |
| Arity mismatch (under-apply) | JS `apply()` | Return new PAp |
| Arity mismatch (over-apply) | JS `apply()` | Throw `ArityError` |
| Resume wrong continuation ID | WASM check | Throw `InvalidContinuationError` |
| Heap exhaustion | Bump allocator overflow | Grow memory or throw `OutOfMemoryError` |

---

## Appendix B: Golden Traces

### Async fetch

```
1. WASM: call $IO_delay_impl_v3
2. WASM: FFI returns YIELD_SENTINEL
3. WASM: Save locals, k_ptr, denv_ptr to AsyncCont
4. WASM: Return YIELD_SENTINEL
5. JS:   Create ContinuationHandle
6. JS:   setTimeout fires
7. JS:   Call __resume(contId, 0n)
8. WASM: Restore state, br_table to resume point
9. WASM: Continue execution
```

### State ability (pure WASM)

```
1. WASM: THnd pushes Mark frame
2. WASM: Execute body, encounter State.get
3. WASM: TShift captures K up to Mark
4. WASM: Look up handler in DEnv
5. WASM: Execute handler, resume continuation
6. WASM: Pop Mark frame, continue
```

### Partial application

```
1. WASM: Evaluate (add 5)
2. WASM: Allocate PAp { arity: 2, captured: [5] }
3. JS:   runtime.apply(pap, 10)
4. JS:   1 + 1 == 2, fully saturated
5. JS:   Call WASM add(5, 10)
6. WASM: Return 15
```

---

## Deferred Items

| Item | Notes |
|------|-------|
| `BX` → `I32` pointer type | Pointers compile to I64 (works, wastes 32 bits) |
| Foreign call signature lookup | Look up from ForeignFunc enum instead of hardcoded |
| Multi-function CLI compilation | CLI compiles single expressions |
