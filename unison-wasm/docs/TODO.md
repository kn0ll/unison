# WASM Backend — TODO

---

## v1.0 Requirements

### Async: Nested/Sequential Support

**Current:** Throws `NestedAsyncError` if you yield while another async is pending.

**Problem:** Can't do sequential async calls:
```unison
-- This breaks today:
a = IO.delay 100
b = IO.delay 200  -- NestedAsyncError!
a + b
```

**Fix:** Support multiple in-flight continuations. Queue or interleave async operations.

---

### Continuation Capture: Liveness Analysis

**Current:** Saves ALL locals when capturing a continuation.

**Problem:** Wastes memory. A function with 20 locals saves all 20, even if only 2 are live.

**Fix:** Compile-time liveness analysis to determine which locals are actually needed.

---

### More IO Builtins

| Task | Description |
|------|-------------|
| `IO.putBytes.impl.v3` | `console.log` / stdout |
| `IO.randomBytes.impl.v1` | `crypto.getRandomValues` |

---

### HTTP in Browser

Unison HTTP uses sockets. Browsers don't expose raw sockets.

**Options:**
1. Intercept at HTTP library level (`Http.request` handler)
2. WebSocket bridge to proxy
3. New `Browser.fetch` ability

---

## Future Work

### New UI Abilities

| Ability | Browser Handler | Server Handler |
|---------|-----------------|----------------|
| `DOM` | Real DOM APIs | Virtual DOM → HTML |
| `Events` | `addEventListener` | Server-side simulation |
| `Storage` | `localStorage` | In-memory map |

---

### Performance Optimizations

| Current | Cost | Optimization |
|---------|------|--------------|
| 16-byte TypedSlot everywhere | 2× memory | Unboxed locals |
| Copy Text/Bytes at boundary | Encode overhead | Zero-copy views |
| WAT text → WASM binary | Slow compile | Direct binary emission |
| No inlining | Call overhead | Inline small functions |

---

## Reference

### Failure Modes

| Scenario | Behavior |
|----------|----------|
| Double resume | `ContinuationConsumedError` |
| Nested async | `NestedAsyncError` |
| Wrong TypeTag in apply | `TypeError` |
| Arity mismatch (under) | Return new PAp |
| Arity mismatch (over) | `ArityError` |
| Wrong continuation ID | `InvalidContinuationError` |
| Heap exhaustion | Grow memory or `OutOfMemoryError` |

### Golden Traces

**Async:**
```
1. call $IO_delay → YIELD_SENTINEL
2. Save locals, k_ptr, denv_ptr to AsyncCont
3. Return YIELD_SENTINEL to JS
4. JS: setTimeout fires → __resume(contId, 0n)
5. Restore state, br_table to resume point
```

**Ability:**
```
1. THnd pushes Mark frame
2. TShift captures K, looks up handler in DEnv
3. Execute handler, resume continuation
```
