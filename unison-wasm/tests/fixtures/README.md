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
├── recursion/       # Recursive functions (factorial, fibonacci)
├── arithmetic/      # Basic math operations
├── pattern-matching/# Match expressions with multiple branches
└── closures/        # Let bindings and closures
```

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

## Abilities

Ability tests (handle/shift/resume) cannot use `.u` fixtures because
the parser doesn't support `handle` syntax. These are tested via
manually constructed ANormal IR in `Abilities.hs`.
