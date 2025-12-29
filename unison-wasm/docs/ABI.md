# WASM ABI Specification

**Version:** 0.1.0

This document defines the memory layout and calling conventions for the Unison WASM runtime. Changes to this specification are breaking changes that require version bumps.

---

## Design Principles

1. **Explicit over implicit**: All runtime values have explicit type tags
2. **Debuggable**: Memory layouts should be inspectable from JS dev tools
3. **Aligned**: All heap allocations are 8-byte aligned for i64/f64 access
4. **Versioned**: Header words include version bits for future evolution
5. **Native-aligned**: Data structures mirror the native Haskell runtime where possible

---

## Alignment with Native Runtime

This section documents how our WASM ABI maps to the native Unison runtime in `unison-runtime/`.
Keeping these aligned ensures behavioral equivalence and eases debugging.

### GClosure → ObjTag Mapping

| Native (`Stack.hs`) | WASM ABI | Notes |
|---------------------|----------|-------|
| `GEnum` | `OBJ_ENUM` (0x001) | Nullary constructor |
| `GData1` | `OBJ_DATA1` (0x002) | 1-field constructor |
| `GData2` | `OBJ_DATA2` (0x003) | 2-field constructor |
| `GDataG` | `OBJ_DATAG` (0x004) | N-field constructor |
| `GPAp` | `OBJ_PAP` (0x005) | Partial application |
| `GCaptured` | `OBJ_CAPTURED` (0x006) | Captured continuation |
| `GForeign` | `OBJ_FOREIGN` (0x007) | Opaque JS handle |
| (WASM-only) | `OBJ_ASYNC_CONT` (0x00B) | Async yield/resume state |
| `GUnboxedTypeTag` | `TYPE_*` constants | Type discriminator for unboxed values |

### K Frame → FrameTag Mapping

| Native (`Stack.hs`) | WASM ABI | Notes |
|---------------------|----------|-------|
| `KE` | `FRAME_KE` (0x00) | Empty continuation (stack bottom) |
| `Push` | `FRAME_PUSH` (0x01) | Normal return frame |
| `Mark` | `FRAME_MARK` (0x02) | Ability handler marker |

### Val → TypedSlot Mapping

| Native | WASM ABI | Notes |
|--------|----------|-------|
| `Val { unboxed :: Int, boxed :: Closure }` | `TypedSlot { TypeTag, Payload64 }` | Conceptually equivalent |
| `GUnboxedTypeTag NatTag` (in boxed slot) | `TYPE_NAT` (in TypeTag) | Type info location differs |
| Unboxed value in `unboxed` field | Value in `Payload64` | Same semantics |

### PackedTag Alignment

Native runtime (`TypeTags.hs`):
```
PackedTag = RTag << 16 | CTag
RTag: 48-bit type reference number
CTag: 16-bit constructor ID
```

Pattern matching uses `maskTags` to extract just the CTag (lower 16 bits) for comparison.
Our `MatchData` compilation correctly compares constructor IDs only.

### Key Differences

| Aspect | Native | WASM | Rationale |
|--------|--------|------|-----------|
| PAp function ref | `CombIx` (Reference + indices) | `func_id` (table index) | WASM uses `call_indirect` |
| RSection caching | Stored in Push frames | Computed from CombIx | Different execution model |
| DEnv | `EnumMap Word64 Closure` | Array-based map | Simpler for WASM |

### Reference Functions

When implementing new features, consult these native runtime functions:

| Function | File | Purpose |
|----------|------|---------|
| `dataBranch` | `Machine.hs` | Pattern matching on data types |
| `splitCont` | `Machine.hs` | Capture continuation up to marker |
| `repush` | `Machine.hs` | Resume captured continuation |
| `buildData` | `Machine.hs` | Construct Enum/Data1/Data2/DataG |
| `closureTag` | `Stack.hs` | Extract PackedTag from closure |
| `maskTags` | `TypeTags.hs` | Extract CTag from PackedTag |

---

## Canonical Terminology

To avoid ambiguity, we define these terms precisely and use them consistently:

### Value & Type Terms

| Term | Definition |
|------|------------|
| `TypeTag` | 8-bit discriminator for `TypedSlot` payload interpretation (`TYPE_NAT`, `TYPE_BOXED`, etc.) |
| `ObjTag` | 12-bit discriminator for heap object kind (`OBJ_ENUM`, `OBJ_PAP`, etc.) |
| `TypedSlot` | 16-byte (TypeTag + Payload64) pair — the universal value representation |
| `Payload64` | Raw 64-bit value (unboxed data OR heap pointer in low 32 bits) |

**Rule:** Never use bare "tag" in prose. Always specify `TypeTag` or `ObjTag`.

### Foreign/FFI Terms

| Term | Definition |
|------|------------|
| `ForeignCall` | IR instruction that invokes a JS host function (may yield for async) |
| `Foreign` (object) | Heap object (`OBJ_FOREIGN`) holding an opaque handle to a JS value |
| `ContinuationHandle` | JS-side object for resuming an async `ForeignCall` (exactly-once) |
| JS host | The JavaScript environment embedding the WASM module |

**Canonical rule:** `ForeignCall` is the instruction; `Foreign` is passive data. Only `ForeignCall` can yield control. `Foreign` values are opaque, non-resumable handles to JS objects (DOM nodes, etc.) — they cannot themselves trigger resumption.

### Continuation Terms

| Term | Definition |
|------|------------|
| `K` | Continuation stack — linked list of frames in linear memory |
| `Push` frame | Return frame storing saved locals and return address |
| `Mark` frame | Ability handler marker frame |
| `Captured` | Heap object storing a captured continuation (K chain + values) |
| resume | Restore a captured continuation and continue execution (exactly once for async) |

**Canonical rule:** A captured continuation restores exactly the chain of `K` frames and the saved locals segments stored in those frames. There is no implicit operand stack beyond what is represented in the saved locals of Push frames.

### Pointer Representation

**Canonical rule:** Pointers are 32-bit offsets into linear memory, stored zero-extended in the low 32 bits of `Payload64`. The high 32 bits are always zero.

### Reference Disambiguation

Two kinds of references exist and **must never be interchanged**:

| Reference Kind | Size | Used In | Points To |
|----------------|------|---------|-----------|
| `TypeRef` | u32 | Constructor objects (`Enum`, `DataN`) | Type table entry (identifies the type) |
| `TermRef` | u32 | `PAp`, function calls, `CombIx` | Term table entry (identifies the combinator) |

**Rule:** A `TypeRef` cannot be used where a `TermRef` is expected, and vice versa. Mixing them will cause pattern matching or function dispatch to fail silently.

---

## Value Representation

### Terminology

To avoid ambiguity, we define precise terms:

| Term | Size | Description |
|------|------|-------------|
| `Payload64` | 64 bits | Raw 64-bit value (unboxed data OR heap pointer) |
| `TypeTag` | 8 bits | Discriminator for payload interpretation |
| `TypedSlot` | 128 bits | A `(TypeTag, Payload64)` pair with padding |

**Important**: A `TypedSlot` is 16 bytes (8 for TypeTag + padding, 8 for Payload64). This is what's stored on the stack and in heap object fields.

**Performance note (MVP tradeoff)**: Using 16-byte TypedSlots everywhere prioritizes correctness and debuggability over performance. This doubles memory bandwidth for sequences and adds tag plumbing overhead. Future optimizations:
- Unboxed locals for known primitive-only functions
- Specialized `Sequence Nat/Int/Float` with packed representations
- Inline caching for hot paths

### Payload64 Encoding

```
┌─────────────────────────────────────────────────────────────────┐
│                       Payload64 (64 bits)                        │
├─────────────────────────────────────────────────────────────────┤
│  For unboxed: the raw value (i64, f64, char as u32, etc.)       │
│  For boxed:   heap pointer in LOW 32 BITS (zero-extended)        │
└─────────────────────────────────────────────────────────────────┘
```

### Pointer Representation (wasm32)

In wasm32, pointers are 32-bit offsets into linear memory:

- Pointers are stored in the **low 32 bits** of `Payload64`
- High 32 bits are always zero (zero-extended)
- All heap addresses are < 4GiB (wasm32 constraint)
- Pointer value `0x00000000` is reserved (null/invalid)

```
┌─────────────────────────────────────────────────────────────────┐
│                    Boxed Payload64 Layout                        │
├────────────────────────────────┬────────────────────────────────┤
│   High 32 bits (always zero)   │   Low 32 bits (heap pointer)   │
└────────────────────────────────┴────────────────────────────────┘
```

### TypeTag Values

Type tags discriminate unboxed values. Use `TYPE_*` prefix (distinct from `OBJ_*` object tags):

| TypeTag | Value | Payload64 Interpretation |
|---------|-------|--------------------------|
| `TYPE_NAT` | `0x00` | Unsigned 64-bit integer |
| `TYPE_INT` | `0x01` | Signed 64-bit integer |
| `TYPE_FLOAT` | `0x02` | IEEE 754 double (f64) |
| `TYPE_CHAR` | `0x03` | Unicode codepoint (u32 in low bits) |
| `TYPE_BOXED` | `0x04` | Heap pointer (u32 in low bits) |

### TypedSlot Layout

Every stack local and heap object field uses this 16-byte layout:

```
┌────────────────────────────────────────────────────────────────┐
│                      TypedSlot (128 bits)                       │
├────────────────┬───────────────────────────────────────────────┤
│ TypeTag (8)    │ Padding (56 bits)                              │  ← bytes 0-7
├────────────────┴───────────────────────────────────────────────┤
│ Payload64 (64 bits)                                             │  ← bytes 8-15
└────────────────────────────────────────────────────────────────┘
```

This uniform layout simplifies codegen and debugging at the cost of some memory.

---

## Heap Object Layout

All heap objects share a common header:

```
┌─────────────────────────────────────────────────────────────────┐
│                      Heap Object Header (64 bits)                │
├────────────┬────────────┬────────────┬──────────────────────────┤
│ Version(4) │ ObjTag(12) │ Reserved(16)│ Size/Arity(32)          │
└────────────┴────────────┴────────────┴──────────────────────────┘
```

| Field | Bits | Description |
|-------|------|-------------|
| Version | 4 | ABI version (currently `0x0`) |
| ObjTag | 12 | Object type (`OBJ_*` constants, see below) |
| Reserved | 16 | For future use (GC bits, etc.) |
| Size/Arity | 32 | Object-specific size or arity |

### ObjTag Values

ObjTag values identify heap object types. Use `OBJ_*` prefix (distinct from `TYPE_*` TypeTag values):

```
OBJ_ENUM       = 0x001  - Nullary data constructor
OBJ_DATA1      = 0x002  - Unary data constructor
OBJ_DATA2      = 0x003  - Binary data constructor
OBJ_DATAG      = 0x004  - General data constructor (N fields)
OBJ_PAP        = 0x005  - Partial application (closure)
OBJ_CAPTURED   = 0x006  - Captured continuation
OBJ_FOREIGN    = 0x007  - Foreign/opaque JS reference
OBJ_TEXT       = 0x008  - UTF-8 text (special handling)
OBJ_BYTES      = 0x009  - Raw byte array
OBJ_SEQUENCE   = 0x00A  - Unison sequence
OBJ_ASYNC_CONT = 0x00B  - Async continuation (yield/resume)
```

---

## Closure Variants

### Enum (OBJ_ENUM = 0x001) - Nullary Constructor

```
┌────────────────────────────────────────┐
│ Header (64 bits)                       │
├────────────────────────────────────────┤
│ TypeRef (32 bits) │ PackedTag (32 bits)│
└────────────────────────────────────────┘
Total: 16 bytes
```

### Data1 (OBJ_DATA1 = 0x002) - Unary Constructor

```
┌────────────────────────────────────────┐
│ Header (64 bits)                       │  ← bytes 0-7
├────────────────────────────────────────┤
│ TypeRef (32 bits) │ PackedTag (32 bits)│  ← bytes 8-15
├────────────────────────────────────────┤
│ Field0: TypedSlot (128 bits)           │  ← bytes 16-31
│   [TypeTag(8) + Pad(56) + Payload64]   │
└────────────────────────────────────────┘
Total: 32 bytes
```

### Data2 (OBJ_DATA2 = 0x003) - Binary Constructor

```
┌────────────────────────────────────────┐
│ Header (64 bits)                       │  ← bytes 0-7
├────────────────────────────────────────┤
│ TypeRef (32 bits) │ PackedTag (32 bits)│  ← bytes 8-15
├────────────────────────────────────────┤
│ Field0: TypedSlot (128 bits)           │  ← bytes 16-31
├────────────────────────────────────────┤
│ Field1: TypedSlot (128 bits)           │  ← bytes 32-47
└────────────────────────────────────────┘
Total: 48 bytes
```

### DataG (OBJ_DATAG = 0x004) - General Constructor

```
┌────────────────────────────────────────┐
│ Header (64 bits) - Size field = N      │  ← bytes 0-7
├────────────────────────────────────────┤
│ TypeRef (32 bits) │ PackedTag (32 bits)│  ← bytes 8-15
├────────────────────────────────────────┤
│ Field0: TypedSlot (128 bits)           │  ← bytes 16-31
├────────────────────────────────────────┤
│ Field1: TypedSlot (128 bits)           │  ← bytes 32-47
├────────────────────────────────────────┤
│ ...                                    │
├────────────────────────────────────────┤
│ FieldN-1: TypedSlot (128 bits)         │
└────────────────────────────────────────┘
Total: 16 + (N * 16) bytes
```

### PAp (OBJ_PAP = 0x005) - Partial Application / Closure

```
┌────────────────────────────────────────┐
│ Header (64 bits) - Size = N (captured) │  ← bytes 0-7
├────────────────────────────────────────┤
│ CombIx: RefId (32) │ CombNum (32)      │  ← bytes 8-15
├────────────────────────────────────────┤
│ ExpectedArity (16) │ CapturedCount (16)│  ← bytes 16-19 (for apply)
│ Reserved (32)                          │  ← bytes 20-23
├────────────────────────────────────────┤
│ Arg0: TypedSlot (128 bits)             │  ← bytes 24-39
├────────────────────────────────────────┤
│ Arg1: TypedSlot (128 bits)             │  ← bytes 40-55
├────────────────────────────────────────┤
│ ...                                    │
└────────────────────────────────────────┘
Total: 24 + (N * 16) bytes
```

| Field | Description |
|-------|-------------|
| `ExpectedArity` | Total args the underlying function expects (u16) |
| `CapturedCount` | Args already captured in this PAp (u16, same as N) |
| `Remaining` | `ExpectedArity - CapturedCount` = args still needed |

**Why store arity in PAp:** The `apply()` function is a hot path. Storing arity here avoids a combinator table lookup on every apply call.

### Captured (OBJ_CAPTURED = 0x006) - Captured Continuation

A captured continuation stores both the **frame chain** (K) and the **captured local values** (Seg) that were live at capture time.

```
┌────────────────────────────────────────┐
│ Header (64 bits) - Size = N (values)   │  ← bytes 0-7
├────────────────────────────────────────┤
│ kHeadPtr (32 bits) │ pendingArgs (32)  │  ← bytes 8-15
├────────────────────────────────────────┤
│ Captured value 0: TypedSlot (128 bits) │  ← bytes 16-31
├────────────────────────────────────────┤
│ Captured value 1: TypedSlot (128 bits) │  ← bytes 32-47
├────────────────────────────────────────┤
│ ...                                    │
└────────────────────────────────────────┘
Total: 16 + (N * 16) bytes
```

| Field | Description |
|-------|-------------|
| `kHeadPtr` | Pointer to first K frame (the continuation chain) |
| `pendingArgs` | Number of pending arguments at capture |
| `Captured values` | Local values that were live on the stack at capture time |

**Note**: The K frames themselves are separately allocated in linear memory (see K Frame Layout). The `kHeadPtr` points to a linked list of these frames. The captured values are the *data* that was on the value stack; the K frames are the *control* (return addresses, handlers).

**Resume semantics**: A captured continuation restores exactly the chain of `K` frames and the saved locals segments stored in those frames. There is no implicit operand stack beyond what is represented in the saved locals of Push frames. The captured values array contains the locals that were live at capture time.

### Foreign (OBJ_FOREIGN = 0x007) - Opaque JS Reference

```
┌────────────────────────────────────────┐
│ Header (64 bits)                       │  ← bytes 0-7
├────────────────────────────────────────┤
│ JS Handle ID (32 bits) │ TypeHint (32) │  ← bytes 8-15
└────────────────────────────────────────┘
Total: 16 bytes
```

Foreign objects hold an opaque handle ID that the JS host maps to actual JS values. This allows GC on the WASM side to release JS references.

**Important**: `Foreign` values are passive data — they cannot trigger resumption or yield control. Only `ForeignCall` instructions can yield. A `Foreign` object might wrap a DOM node, a JS object, or other JS-side data, but invoking methods on it requires a `ForeignCall`.

### Text (OBJ_TEXT = 0x008) - UTF-8 String

```
┌────────────────────────────────────────┐
│ Header (64 bits) - Size = byteLen      │  ← bytes 0-7
├────────────────────────────────────────┤
│ ByteLen (32 bits) │ CharLen (32 bits)  │  ← bytes 8-15
├────────────────────────────────────────┤
│ UTF-8 bytes (variable length)          │  ← bytes 16+
│ ... padded to 8-byte alignment         │
└────────────────────────────────────────┘
Total: 16 + ceil8(byteLen) bytes
```

| Field | Description |
|-------|-------------|
| `ByteLen` | Length in bytes (for memory operations) |
| `CharLen` | Length in Unicode codepoints (for `Text.size`) |
| `UTF-8 bytes` | Raw UTF-8 encoded content, NOT null-terminated |

**Immutability**: Text values are immutable. The JS host may read them but must not mutate in place. Any modification creates a new Text object.

**Performance note (MVP tradeoff)**: MVP always copies Text across the WASM/JS boundary (encode on write, decode on read). For DOM-heavy apps with frequent text crossing, this can be costly. Future optimizations:
- Zero-copy JS views over WASM memory for short-lived read access
- Rope/chunked text for large string manipulation
- Cached JS string for frequently-accessed Text objects

**Interop with JS**: The JS host can read Text via:
```javascript
function getText(ptr) {
  const byteLen = mem.getUint32(ptr + 8, true);
  const bytes = new Uint8Array(mem.buffer, ptr + 16, byteLen);
  return new TextDecoder().decode(bytes);
}
```

**Future**: May add cached hash for interning.

### Bytes (OBJ_BYTES = 0x009) - Raw Byte Array

```
┌────────────────────────────────────────┐
│ Header (64 bits) - Size = len          │  ← bytes 0-7
├────────────────────────────────────────┤
│ Length (32 bits) │ Reserved (32 bits)  │  ← bytes 8-15
├────────────────────────────────────────┤
│ Raw bytes (variable length)            │  ← bytes 16+
│ ... padded to 8-byte alignment         │
└────────────────────────────────────────┘
Total: 16 + ceil8(len) bytes
```

**Immutability**: Bytes values are immutable. The JS host may read them but must not mutate in place. Any modification creates a new Bytes object.

### Sequence (OBJ_SEQUENCE = 0x00A) - Unison List/Array

```
┌────────────────────────────────────────┐
│ Header (64 bits) - Size = N            │  ← bytes 0-7
├────────────────────────────────────────┤
│ Length (32 bits) │ Capacity (32 bits)  │  ← bytes 8-15
├────────────────────────────────────────┤
│ Element 0: TypedSlot (128 bits)        │  ← bytes 16-31
├────────────────────────────────────────┤
│ Element 1: TypedSlot (128 bits)        │  ← bytes 32-47
├────────────────────────────────────────┤
│ ...                                    │
└────────────────────────────────────────┘
Total: 16 + (N * 16) bytes
```

**Note**: This is a simple array representation. Future optimizations may use finger trees or other structures for efficient concatenation.

### AsyncCont (OBJ_ASYNC_CONT = 0x00B) - Async Continuation

```
┌────────────────────────────────────────┐
│ Header (64 bits) - ObjTag=0x00B        │  ← bytes 0-7
├────────────────────────────────────────┤
│ ContId (64 bits)                       │  ← bytes 8-15
├────────────────────────────────────────┤
│ KPtr (32) │ LocalsPtr (32)             │  ← bytes 16-23
├────────────────────────────────────────┤
│ LocalsCount (32) │ Status (32)         │  ← bytes 24-31
└────────────────────────────────────────┘
Total: 32 bytes
```

| Field | Description |
|-------|-------------|
| `ContId` | Unique ID for JS-side `ContinuationHandle` reference |
| `KPtr` | Saved K stack pointer |
| `LocalsPtr` | Pointer to saved locals array |
| `LocalsCount` | Number of saved locals |
| `Status` | 0=pending, 1=resumed, 2=freed |

**Linearity**: Each async continuation is resumed **exactly once**. The JS runtime enforces this via the `ContinuationHandle.consumed` flag.

---

## Continuation Stack (K) Layout

The continuation stack is a linked list of frames in linear memory:

### Frame Header (common to all frame types)

```
┌────────────────────────────────────────┐
│ FrameTag (8) │ Reserved (24) │ Next(32)│
└────────────────────────────────────────┘
```

| FrameTag | Name | Description |
|----------|------|-------------|
| `0x00` | KE | Empty (end of chain) |
| `0x01` | Push | Return frame |
| `0x02` | Mark | Ability handler marker |

### Push Frame (FrameTag 0x01)

```
┌────────────────────────────────────────┐
│ FrameTag=0x01 │ Reserved │ Next (32)   │  ← bytes 0-7
├────────────────────────────────────────┤
│ SavedCount (32) │ PendingArgs (32)     │  ← bytes 8-15
├────────────────────────────────────────┤
│ CombIx: Reference (32) │ Comb# (32)    │  ← bytes 16-23
├────────────────────────────────────────┤
│ Saved[0]: TypedSlot (128 bits)         │  ← bytes 24-39
├────────────────────────────────────────┤
│ Saved[1]: TypedSlot (128 bits)         │  ← bytes 40-55
├────────────────────────────────────────┤
│ ...                                    │
├────────────────────────────────────────┤
│ Saved[SavedCount-1]: TypedSlot         │
└────────────────────────────────────────┘
Total: 24 + (SavedCount * 16) bytes
```

| Field | Description |
|-------|-------------|
| `SavedCount` | Number of locals saved in this frame (u32) |
| `PendingArgs` | Number of pending arguments at call site |
| `CombIx` | Combinator reference + index for return |
| `Saved[...]` | Saved local values as TypedSlots |

**Note:** The native runtime has a `StackGuard` field for stack growth hints. WASM linear memory can grow dynamically, so this field is omitted.

**MVP Rule for SavedCount:**
- `SavedCount` = total locals declared by the calling function (static, from codegen)
- All locals are saved, not just live ones (simplifies implementation)

**Performance note (MVP tradeoff)**: Saving all locals trades continuation size for simplicity. Functions with many locals will produce large Push frames (24 + N×16 bytes each). This can cause:
- Large captured continuations in heap
- Heap pressure during frequent ability usage
- Latency spikes when capturing on async yield

Future optimizations:
- Liveness-based `SavedCount` (only save live locals)
- Segmented frames (separate hot/cold locals)
- Exclude temporary spill slots from capture

**Capture/Restore Contract:**
- `TShift` copies exactly `24 + (SavedCount * 16)` bytes per Push frame
- Resume restores exactly these bytes back to the value stack
- This is deterministic: both sides compute the same size from `SavedCount`

### Mark Frame (FrameTag 0x02)

```
┌────────────────────────────────────────┐
│ FrameTag=0x02 │ Reserved │ Next (32)   │
├────────────────────────────────────────┤
│ PendingArgs (32) │ AbilitySet ptr (32) │
├────────────────────────────────────────┤
│ SavedDEnv pointer (32) │ Reserved (32) │
└────────────────────────────────────────┘
```

---

## Stack Frame Layout

Each function call uses a contiguous region of the WASM linear memory as its stack frame. Stack slots are `TypedSlot` values (16 bytes each):

```
┌────────────────────────────────────────┐
│ Frame Pointer (FP)                     │
├────────────────────────────────────────┤
│ Local 0: TypedSlot                     │  ← FP + 0  (16 bytes)
│   [TypeTag(8) + Pad(56) + Payload64]   │
├────────────────────────────────────────┤
│ Local 1: TypedSlot                     │  ← FP + 16 (16 bytes)
│   [TypeTag(8) + Pad(56) + Payload64]   │
├────────────────────────────────────────┤
│ ...                                    │
├────────────────────────────────────────┤
│ Stack Pointer (SP) →                   │
└────────────────────────────────────────┘
```

Each local slot is a `TypedSlot` (16 bytes): 8 bytes for type tag + padding, 8 bytes for `Payload64`.

---

## Reference Encoding

Type and term references are encoded as 32-bit indices into reference tables:

```
┌────────────────────────────────────────┐
│ RefKind (2) │ Index (30)               │
└────────────────────────────────────────┘
```

| RefKind | Description |
|---------|-------------|
| `0b00` | Builtin reference (index into builtin table) |
| `0b01` | Derived reference (index into term table) |
| `0b10` | Type reference (index into type table) |
| `0b11` | Reserved |

---

## PackedTag Encoding

Constructor tags are packed as in the native runtime:

```
┌────────────────────────────────────────┐
│ RTag (16 bits) │ CTag (16 bits)        │
└────────────────────────────────────────┘
```

- `RTag`: Runtime type tag (for distinguishing types at runtime)
- `CTag`: Constructor tag (0-indexed within the type)

---

## Foreign Handle Table

JS values are not directly accessible from WASM. Instead, we maintain a handle table:

```javascript
// JS side
const foreignHandles = new Map();  // handleId -> JS value
let nextHandleId = 1;

function allocHandle(value) {
  const id = nextHandleId++;
  foreignHandles.set(id, value);
  return id;
}

function freeHandle(id) {
  foreignHandles.delete(id);
}

function getHandle(id) {
  return foreignHandles.get(id);
}
```

When WASM allocates a `Foreign` object, it calls `allocHandle` to get an ID. When the WASM GC collects a `Foreign` object, it calls `freeHandle`.

---

## Versioning

The 4-bit version field in object headers allows for ABI evolution:

| Version | Status | Notes |
|---------|--------|-------|
| `0x0` | Draft | Initial development version |
| `0x1` | (future) | First stable release |

Code should check the version field and fail gracefully on unknown versions.

---

## Alignment Requirements

| Type | Alignment |
|------|-----------|
| All heap objects | 8 bytes |
| Stack frames | 8 bytes |
| K frames | 8 bytes |

---

## Memory Layout Overview

```
┌─────────────────────────────────────────────────────────────────┐
│ 0x0000 - 0x0FFF: Null trap zone (4KB)                           │
│         Any access here indicates a bug (null pointer deref)    │
├─────────────────────────────────────────────────────────────────┤
│ 0x1000 - 0x1FFF: Runtime globals                                │
│         $k_ptr, $heap_ptr, $stack_ptr, $async_state, etc.       │
├─────────────────────────────────────────────────────────────────┤
│ 0x2000 - 0x3FFF: Reference tables (builtins, terms, types)      │
├─────────────────────────────────────────────────────────────────┤
│ 0x4000+: Heap region (bump allocated)                           │
│                        ↑ grows UP ($heap_ptr advances)          │
│         ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─              │
│                        ↓ grows DOWN ($stack_ptr retreats)       │
│ (top of memory): Stack region                                   │
└─────────────────────────────────────────────────────────────────┘
```

**Growth model:** Heap grows UP from 0x4000, stack grows DOWN from top of memory. They share the space between them. Collision triggers memory growth or `OutOfMemoryError`.

---

## Foreign Call Semantics

Foreign calls cross the WASM/JS boundary. This section defines the contract between WASM and JS.

### Call Categories

| Category | Sync/Async | Continuation | Example |
|----------|------------|--------------|---------|
| `Sync` | Synchronous | None | `Math.sin`, `Date.now` |
| `AsyncLinear` | Asynchronous | Exactly-once | `fetch`, `setTimeout` |

### Sync Foreign Calls

Sync calls are simple WASM imports that return immediately:

```wat
(import "js" "dateNow" (func $dateNow (result i64)))
```

No continuation is captured. These are unrestricted.

### Async Foreign Calls (Linear)

Async calls yield control to JS with a continuation handle:

```
WASM                          JS
  │                            │
  ├─── yield(funcId, args) ───►│
  │    [K saved in memory]     │
  │                            ├── do async work
  │                            │
  │◄── resume(contId, result)──┤
  │    [K restored]            │
  ▼                            │
```

### Continuation Handle Layout

When WASM yields for async, it allocates a handle:

```
┌────────────────────────────────────────┐
│ ContinuationHandle (in JS)             │
├────────────────────────────────────────┤
│ continuationId: u32  (WASM memory ptr) │
│ consumed: bool       (exactly-once)    │
│ asyncState: enum     (pending/done)    │
└────────────────────────────────────────┘
```

### Invariants (MVP)

These invariants MUST be enforced:

1. **Linearity**: Each continuation is resumed exactly once
2. **No nesting**: Cannot start async call B while async call A is pending
3. **Ownership**: JS owns the handle; WASM memory is borrowed until resume
4. **Error paths count**: Resuming with an error still consumes the continuation

**Important limitation**: The "no nesting" rule will block common patterns like sequential fetches (`fetch A` then `fetch B` in the same handler chain) and event handlers that trigger async while another is pending. This is acceptable for MVP but needs a design escape hatch.

**Future design (not MVP)**: Queue pending `ForeignCall` requests when async is in-flight. Resume drains queue in FIFO order before continuing execution:

```
┌─────────────────────────────────────────────────────────────┐
│ asyncQueue: [ ForeignCall(fetch, "B"), ForeignCall(log) ]   │
│ asyncState: pending (waiting on fetch A)                    │
└─────────────────────────────────────────────────────────────┘

On resume(resultA):
  1. Continue execution with resultA
  2. If execution yields again for fetch B, it's now the active async
  3. Repeat until queue drains
```

This enables sequential async without reentrancy or multiple outstanding continuations.

### Runtime Globals (0x1000 - 0x1FFF)

```
┌────────────────────────────────────────┐
│ 0x1000: Runtime Globals                │
├────────────────────────────────────────┤
│ +0x00: $k_ptr (i32) - K frame chain    │
│ +0x04: $heap_ptr (i32) - bump alloc    │
│ +0x08: $stack_ptr (i32) - stack top    │
│ +0x0C: $async_state (i32) - 0/1        │
│ +0x10: $async_cont_id (i32)            │
│ +0x14: (reserved for future use)       │
└────────────────────────────────────────┘
```

**Note:** All globals are also exposed as WASM globals for efficient access. The linear memory copy is for debugging/introspection.

The `asyncState` global is checked on yield:
- If already `pending`, throw `NestedAsyncError`
- On resume, reset to `none`

### Violation Behavior

| Violation | Detection Point | Error |
|-----------|----------------|-------|
| Double resume | JS `ContinuationHandle.resume()` | `ContinuationConsumedError` |
| Nested async | WASM yield instruction | `NestedAsyncError` |
| Resume wrong ID | WASM resume check | `InvalidContinuationError` |
| Leaked continuation | (Future) weak ref GC | Warning log |

---

## Apply Protocol

The WASM runtime exports a general-purpose `apply(closure_ptr, arg_ptr) → result_ptr` function that allows the JavaScript host to invoke any Unison closure stored in linear memory.

### Why Apply is Necessary

When Unison code returns values containing closures (callbacks, function fields in records, partial applications), the JS host needs a way to invoke them later:

| Scenario | What Unison Returns | What JS Does |
|----------|---------------------|--------------|
| Event handlers | `onClick : () -> {Dom} ()` | Invoke on button click |
| Callbacks | `onSuccess : Text -> ()` | Invoke when fetch completes |
| Iterators | `next : () -> Optional a` | Call repeatedly to drain |
| Partial application | `addFive : Nat -> Nat` (PAp) | Apply to values later |

Without `apply`, JS can only call statically-exported functions.

### Apply Semantics

**Signature (MVP — single-argument apply):**

```wat
(func $apply (param $closure_ptr i32) (param $arg_slot_ptr i32) (param $result_slot_ptr i32) (result i32))
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `closure_ptr` | u32 | Pointer to PAp object in heap |
| `arg_slot_ptr` | u32 | Pointer to TypedSlot (16 bytes) containing the argument |
| `result_slot_ptr` | u32 | Pointer to TypedSlot (16 bytes) for result (caller-provided) |
| Return | i32 | 0 = success, 1 = yield (async), negative = error |

**All parameters are pointers to TypedSlots in linear memory.** This maintains consistency with our TypedSlot-everywhere approach. The caller is responsible for allocating the result slot.

**Alternative for JS convenience** (wrapper over core):
```javascript
// JS wrapper that handles TypedSlot encoding/decoding
runtime.apply(closurePtr, jsValue) → jsValue
```

| Step | Action |
|------|--------|
| 1 | Read PAp at `closure_ptr` |
| 2 | Check `CapturedCount < ExpectedArity` |
| 3 | Type-check arg's TypeTag against expected |
| 4 | If one more arg needed → call function, write result to `result_slot_ptr` |
| 5 | If more args still needed → allocate new PAp, write pointer to `result_slot_ptr` |

**Multi-argument apply (future):**
```wat
(func $applyN (param $closure_ptr i32) (param $argv_ptr i32) (param $argc i32) (param $result_slot_ptr i32) (result i32))
```
Where `argv_ptr` points to an array of `argc` TypedSlots.

### Result Types

The result is always a `TypedSlot` pointer:

| Condition | Result |
|-----------|--------|
| Fully applied, returns value | Pointer to result TypedSlot |
| Partially applied | Pointer to new PAp (one more arg captured) |
| Triggers async ForeignCall | Yield marker (see below) |

### Async Behavior

If applying the closure triggers an async `ForeignCall`:

```javascript
const result = runtime.apply(closure, arg);
if (runtime.isYield(result)) {
  // Closure yielded for async operation
  const handle = runtime.getContinuationHandle();
  // ... do async work ...
  handle.resume(asyncResult);  // exactly once
} else {
  // Synchronous result
  return runtime.readValue(result);
}
```

This matches the existing yield/resume model for foreign calls.

### Type Safety

**Compile-time (TypeScript):**

Generated `.d.ts` files provide full type safety:

```typescript
// Generated types
interface Closure<Args extends any[], Return> {
  __closure: true;
  __args: Args;
  __return: Return;
}

// Generic apply with type inference
function apply<A, R>(closure: Closure<[A], R>, arg: A): R;
function apply<R>(closure: Closure<[], R>): R;

// Usage - TS catches errors at compile time
const widget = makeButton("Click");     // TS knows: Widget
apply(widget.onClick);                   // Valid
apply(widget.onClick, 42);               // Error: expected 0 args
apply(widget.render);                    // Error: expected 1 arg
apply(widget.render, view);              // Valid
```

**Runtime (fallback):**

For plain JS or dynamic scenarios, apply checks TypeTag:

```javascript
// In apply():
if (arg.tag !== expectedTypeTag) {
  throw new TypeError(`apply: expected ${expectedTypeName}, got ${actualTypeName}`);
}
```

This catches mismatches like passing a Nat where a Boxed closure is expected.

### TypeScript Definition Generation

The compiler emits `.d.ts` alongside `.wasm`:

```typescript
// mymodule.d.ts (auto-generated)

// All Unison types that can cross the boundary
interface Widget {
  render: Closure<[View], Html>;
  onClick: Closure<[], void>;
}

// Exported functions
export function makeButton(label: string): Widget;
export function apply<A, R>(closure: Closure<[A], R>, arg: A): R;
```

**Key property:** TypeScript inference flows through the entire call chain, providing compile-time safety for arbitrary ad-hoc closures.

---

## Appendix A: Terminology Quick Reference

| Term | Size | Native Equivalent |
|------|------|-------------------|
| `Payload64` | 64 bits | The raw `Int` in a `Val` |
| `TypeTag` | 8 bits | `UnboxedTypeTag` |
| `TypedSlot` | 128 bits | `Val` (TypeTag + Payload64 together) |

## Appendix B: Mapping to Native Runtime

| WASM ABI | Native Runtime (Stack.hs) |
|----------|--------------------------|
| `Enum` | `GEnum` |
| `Data1` | `GData1` |
| `Data2` | `GData2` |
| `DataG` | `GDataG` |
| `PAp` | `GPAp` |
| `Captured` | `GCaptured` |
| `Foreign` | `GForeign` |
| `Text` | `Foreign (Wrap Rf.textRef ...)` |
| `Bytes` | `Foreign (Wrap Rf.bytesRef ...)` |
| `Sequence` | `USeq` (Seq Val) |
| `AsyncCont` | (WASM-only, for async yield/resume) |
| `K` frames | `data K` |
| `TypedSlot` | `Val` |
| `TypeTag` | `UnboxedTypeTag` |

## Appendix C: Constants

These constants should be code-generated from this spec to ensure consistency:

```
// Object tags (OBJ_* prefix) - identify heap object types
OBJ_ENUM       = 0x001
OBJ_DATA1      = 0x002
OBJ_DATA2      = 0x003
OBJ_DATAG      = 0x004
OBJ_PAP        = 0x005
OBJ_CAPTURED   = 0x006
OBJ_FOREIGN    = 0x007
OBJ_TEXT       = 0x008
OBJ_BYTES      = 0x009
OBJ_SEQUENCE   = 0x00A
OBJ_ASYNC_CONT = 0x00B

// Type tags (TYPE_* prefix) - discriminate TypedSlot payloads
TYPE_NAT      = 0x00
TYPE_INT      = 0x01
TYPE_FLOAT    = 0x02
TYPE_CHAR     = 0x03
TYPE_BOXED    = 0x04

// K frame tags (FRAME_* prefix) - identify continuation frame types
FRAME_KE      = 0x00
FRAME_PUSH    = 0x01
FRAME_MARK    = 0x02

// Sizes (bytes)
TYPED_SLOT_SIZE   = 16
HEADER_SIZE       = 8
PAP_HEADER_SIZE   = 24  // header + CombIx + arity fields
PUSH_FRAME_HEADER = 24  // fixed header before saved locals (see Push Frame layout)
ASYNC_CONT_SIZE   = 32  // async continuation object size

// Async continuation status values
ASYNC_STATUS_PENDING  = 0
ASYNC_STATUS_RESUMED  = 1
ASYNC_STATUS_FREED    = 2

// Yield sentinel (magic value indicating async yield)
YIELD_SENTINEL = 0xFFFFFFFFFFFFFFFE  // cannot be valid Nat/Int/pointer

// Memory layout (canonical: heap UP, stack DOWN)
MEMORY_NULL_ZONE_START  = 0x0000
MEMORY_NULL_ZONE_END    = 0x0FFF
MEMORY_GLOBALS_START    = 0x1000
MEMORY_GLOBALS_END      = 0x1FFF
MEMORY_REFTABLES_START  = 0x2000
MEMORY_REFTABLES_END    = 0x3FFF
MEMORY_HEAP_START       = 0x4000  // Heap grows UP from here
// Stack grows DOWN from top of memory
```
