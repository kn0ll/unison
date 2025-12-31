# Maps in Unison WASM

This document outlines the strategy for supporting Unison's `Map k v` type in WASM.

---

## Current State

We support:
- ✅ Primitives (Nat, Int, Float, Boolean)
- ✅ Text (UTF-8 encoded on heap)
- ✅ Records/Product types (DataG with positional fields)
- ✅ Sum types (DataG with constructor tags)
- ❌ Maps (tree structures)

---

## Unison's Map Type

Unison's `Map k v` is a **persistent balanced tree** (similar to Haskell's `Data.Map`).

```unison
-- Conceptual structure (simplified)
type Map k v
  = Empty
  | Node (Map k v) k v (Map k v)
```

In memory, this becomes a tree of `DataG` objects with pointers to children.

---

## Serialization Strategies

### Option 1: Tree Traversal (Preserve Structure)

Walk the tree in WASM memory, recursively reading nodes.

```typescript
interface MapNode<K, V> {
  left: MapNode<K, V> | null;
  key: K;
  value: V;
  right: MapNode<K, V> | null;
}

function readMap<K, V>(ptr: number): Map<K, V> {
  const node = runtime.readDataGFields(ptr);
  const ctorTag = runtime.getCtorTag(ptr);

  if (ctorTag === 0) return new Map(); // Empty

  // Node constructor
  const [leftPtr, key, value, rightPtr] = node;
  const result = new Map<K, V>();

  // Recursively read subtrees
  readMapInto(result, leftPtr);
  result.set(parseKey(key), parseValue(value));
  readMapInto(result, rightPtr);

  return result;
}
```

**Pros**: Preserves all data, works with any key/value types
**Cons**: Recursive, complex, needs type info for keys/values

---

### Option 2: Flatten to List (Simple Interop)

In Unison, convert Map to list before returning:

```unison
-- Return a list of key-value pairs
getPrices : '{IO} [(Text, Nat)]
getPrices _ =
  prices
    |> Map.toList
```

Then parse the list in JS:

```typescript
function readList(ptr: number): [unknown, unknown][] {
  // List is Cons head tail | Nil
  // Recursively read until Nil
}
```

**Pros**: Simpler parsing, no tree recursion
**Cons**: Loses tree structure, O(n) conversion on Unison side

---

### Option 3: JSON Serialization

Serialize the Map to JSON Text in Unison, parse in JS:

```unison
toJson : Map Text Nat -> Text
toJson m = Json.serialize (Map.toList m)
```

```typescript
const jsonPtr = await runtime.run('getPricesJson');
const jsonText = runtime.getText(jsonPtr);
const prices = JSON.parse(jsonText);
```

**Pros**: Trivial JS parsing, human-readable
**Cons**: Text encoding overhead, only works for JSON-compatible types

---

## Recommended Approach

### Phase 1: List Flattening (MVP)

For the demo, use `Map.toList` in Unison:

```unison
type PriceMap = PriceMap [(Text, Nat)]

getPriceMap : Nat -> PriceMap
getPriceMap qty =
  items = [("subtotal", qty * 1000), ("discount", ...)]
  PriceMap items
```

Parse in JS:

```typescript
function readPriceMap(ptr: number): Record<string, number> {
  const fields = runtime.readDataGFields(ptr);
  const listPtr = Number(fields[0]);
  return readListAsObject(listPtr);
}

function readListAsObject(ptr: number): Record<string, number> {
  const result: Record<string, number> = {};
  let current = ptr;

  while (true) {
    const ctorTag = runtime.getCtorTag(current);
    if (ctorTag === 0) break; // Nil

    // Cons (k, v) tail
    const [pairPtr, tailPtr] = runtime.readDataGFields(current);
    const [keyPtr, value] = runtime.readDataGFields(Number(pairPtr));

    const key = runtime.getText(Number(keyPtr));
    result[key] = Number(value);

    current = Number(tailPtr);
  }

  return result;
}
```

### Phase 2: Type-Aware Parsing

Add type metadata to enable generic Map parsing:

```typescript
// Type registry from Unison codebase
const typeRegistry = {
  'Map': { kind: 'tree', keyType: 'Text', valueType: 'Nat' },
  'List': { kind: 'list', elemType: 'Tuple' },
};

function readTyped(ptr: number, typeName: string): unknown {
  const typeInfo = typeRegistry[typeName];
  switch (typeInfo.kind) {
    case 'tree': return readTree(ptr, typeInfo);
    case 'list': return readList(ptr, typeInfo);
    // ...
  }
}
```

### Phase 3: Direct Tree Support

For performance-critical cases, support direct tree reading:

```typescript
class UnisonMap<K, V> {
  private root: number; // Pointer to WASM heap

  get(key: K): V | undefined {
    // Binary search in WASM memory directly
    // No full tree copy needed
  }

  toJS(): Map<K, V> {
    // Full conversion when needed
  }
}
```

---

## API Design

### Runtime Methods

```typescript
interface UnisonRuntime {
  // Existing
  readDataGFields(ptr: number): bigint[];
  getCtorTag(ptr: number): number;

  // New for Maps
  readList<T>(ptr: number, parseElem: (ptr: number) => T): T[];
  readMap<K, V>(ptr: number, parseKey: ..., parseValue: ...): Map<K, V>;
  readMapAsObject(ptr: number): Record<string, unknown>; // Text keys only
}
```

### Type Hints

Since WASM loses type info, provide hints:

```typescript
// Option A: Explicit type parameter
const prices = runtime.readMap<string, number>(ptr, 'Text', 'Nat');

// Option B: Schema object
const prices = runtime.read(ptr, {
  type: 'Map',
  key: 'Text',
  value: 'Nat',
});

// Option C: Generated types from Unison
import { PriceMap } from './generated/pricing.types';
const prices = runtime.read<PriceMap>(ptr);
```

---

## Implementation Checklist

- [ ] Add `getCtorTag(ptr)` to UnisonRuntime
- [ ] Add `readList(ptr, parser)` for Cons/Nil lists
- [ ] Add `readMapAsObject(ptr)` for Text-keyed maps
- [ ] Add `readMap(ptr, keyParser, valueParser)` generic version
- [ ] Document Map serialization patterns in README
- [ ] Add tests for nested structures

---

## Example: Price Breakdown with Dynamic Keys

```unison
type Breakdown = Breakdown (Map Text Nat)

calculateBreakdown : Nat -> Breakdown
calculateBreakdown qty =
  entries = Map.fromList
    [ ("unit_price", 1000)
    , ("quantity", qty)
    , ("subtotal", qty * 1000)
    , ("discount", if qty >= 5 then qty * 100 else 0)
    , ("total", qty * 1000 - (if qty >= 5 then qty * 100 else 0))
    ]
  Breakdown entries
```

```typescript
const ptr = await runtime.run('calculateBreakdown', 5n);
const breakdown = runtime.readMapAsObject(ptr);
// { unit_price: 1000, quantity: 5, subtotal: 5000, discount: 500, total: 4500 }
```

---

## See Also

- [ABI.md](./ABI.md) - Memory layout for DataG objects
- [FFI.md](./FFI.md) - Foreign function interface
- [ASYNC.md](./ASYNC.md) - Async yield/resume for IO operations

