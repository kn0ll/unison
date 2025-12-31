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

### TypeScript Generation: Wire Up

**Current:** `TypeScript.hs` exists but isn't called from compiler. Manual parsing required:
```typescript
// Manual (bad):
const fields = runtime.readDataGFields(ptr);  // bigint[]
return { subtotal: fields[0], discount: fields[1], total: fields[2] };
```

**Problem:** No type safety, manual parsing for every record type.

**Fix:** Wire up `TypeScript.hs` to emit types during compile:
```typescript
// Generated (good):
export type PriceResult = [bigint, bigint, bigint];
export function read_PriceResult(ptr: bigint): PriceResult;
```

---

### Performance Optimizations

| Current | Cost | Optimization |
|---------|------|--------------|
| 16-byte TypedSlot everywhere | 2× memory | Unboxed locals |
| Copy Text/Bytes at boundary | Encode overhead | Zero-copy views |
| No inlining | Call overhead | Inline small functions |

---
