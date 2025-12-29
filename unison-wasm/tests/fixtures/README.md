# WASM Backend Test Fixtures

These `.u` files contain Unison code that is:
1. **Parsed** by the test suite
2. **Run through the native Unison runtime** → Result A
3. **Compiled to WASM and run via wasmtime** → Result B
4. **Compared**: if A == B, the test passes

## No Hardcoded Expected Values

There are no `.expected` files. The native Unison runtime is the source of truth.
If native says `120`, WASM must produce `120`.

## Directory Structure

```
fixtures/
├── arithmetic/       # Nat/Int operations (+, -, *, /, mod)
├── recursion/        # Recursive functions (factorial, fibonacci)
├── pattern-matching/ # Match expressions with multiple branches
└── closures/         # Let bindings, higher-order functions, partial application
```

## Feature Coverage

| Feature | Covered | Notes |
|---------|---------|-------|
| Nat arithmetic | ✅ | +, sub, *, /, mod |
| Int arithmetic | ✅ | +, -, *, /, mod |
| Float arithmetic | ✅ | +, -, *, / (reinterpreted as i64) |
| Comparisons | ✅ | <, <=, == (returns Boolean as 0/1) |
| Boolean matching | ✅ | match on true/false |
| Pattern matching | ✅ | Multi-branch, zero-case |
| Recursion | ✅ | Direct recursion |
| Let bindings | ✅ | Simple and nested |
| Higher-order functions | ✅ | Functions as arguments |
| Partial application | ✅ | Creating closures |
| **Abilities** | ⚠️ | Tested in `Abilities.hs` (parser limitation) |
| **Foreign calls** | ⚠️ | Tested in `Abilities.hs` (needs JS runtime) |

## Adding a New Fixture

1. Create a `.u` file in the appropriate subdirectory
2. The test suite will automatically discover and run it
3. The test compares native runtime output to WASM output

Example `.u` file:

```unison
-- Comments are filtered out
let factorial n = match n with
  0 -> 1
  _ -> ##Nat.* n (factorial (##Nat.sub n 1))
factorial 5
```

## Known Limitations

1. **Abilities**: The parser doesn't support `handle` syntax, so ability tests
   use manually constructed ANormal IR in `Abilities.hs`.

2. **Foreign calls**: Require a JS runtime to execute, so they're tested via
   unit tests in `Abilities.hs` that verify import generation.

3. **Complex sum types (Optional, List, etc.)**: Require full data constructor
   support. Basic Boolean (true/false) works.
