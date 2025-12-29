# WASM Backend Testing Strategy

## The Correctness Criterion

> **For any Unison program, the WASM output must equal the native runtime output.**

```
                    ┌──────────────────┐
Unison Code ───────▶│ Native Runtime   │───▶ Result A
     │              └──────────────────┘
     │              
     │              ┌──────────────────┐
     └─────────────▶│ WASM Backend     │───▶ wasmtime ───▶ Result B
                    └──────────────────┘

                    Assert: A == B
```

---

## How Fixtures Work

The `tests/fixtures/` directory contains `.u` files with Unison code.

The test suite (`Fixtures.hs`) automatically:
1. **Discovers** all `.u` files recursively
2. **Parses** each file
3. **Runs through native Unison runtime** → gets Result A
4. **Compiles to WASM and runs via wasmtime** → gets Result B
5. **Compares** A == B

**There are no hardcoded expected values.** The native runtime is the source of truth.

---

## Test Output

```
$ stack test unison-wasm --test-arguments fixtures

✓ Native=200 WASM=200
🦄  fixtures.pattern-matching.multi-branch
✓ Native=42 WASM=42
🦄  fixtures.arithmetic.basic
✓ Native=15 WASM=15
🦄  fixtures.closures.let-binding
✓ Native=55 WASM=55
🦄  fixtures.recursion.fibonacci
✓ Native=120 WASM=120
🦄  fixtures.recursion.factorial

5 tests passed
```

---

## Directory Structure

```
unison-wasm/tests/
├── Suite.hs                        # Entry point
├── Unison/Test/Wasm/
│   ├── Fixtures.hs                 # AUTO-DISCOVERS .u files, compares native vs WASM
│   ├── Integration.hs              # E2E tests via wasmtime
│   ├── Abilities.hs                # Ability tests (manually constructed IR)
│   ├── Compile.hs                  # Compilation unit tests
│   └── ABI.hs                      # ABI constant tests
│
└── fixtures/                       # Human-readable Unison code
    ├── recursion/factorial.u
    ├── recursion/fibonacci.u
    ├── arithmetic/basic.u
    ├── pattern-matching/multi-branch.u
    └── closures/let-binding.u
```

---

## Running Tests

```bash
# All 259 tests
stack test unison-wasm --fast

# Just fixtures (native vs WASM comparison)
stack test unison-wasm --test-arguments fixtures

# Specific category
stack test unison-wasm --test-arguments integration
stack test unison-wasm --test-arguments abilities
```

---

## For Expert Review

The `tests/fixtures/*.u` files contain readable Unison code.

**To verify:**

1. Read `tests/fixtures/recursion/factorial.u` — it's just `factorial 5`
2. Run in UCM — confirms it returns 120
3. Run `stack test unison-wasm` — confirms native runtime = 120, WASM = 120

**Time required:** ~10 minutes

The expert doesn't need to read Haskell or WAT. Just Unison.

---

## Abilities Tests

Ability tests (`handle`/`shift`/`resume`) cannot use `.u` fixtures because
the parser doesn't support `handle` syntax. These are tested via manually
constructed ANormal IR in `Abilities.hs`.

---

## Test Categories

| Category | File | What It Tests |
|----------|------|---------------|
| Fixtures | `Fixtures.hs` | Native vs WASM comparison for .u files |
| Integration | `Integration.hs` | Compile + run via wasmtime |
| Abilities | `Abilities.hs` | Handler, shift, resume, locals |
| Compile | `Compile.hs` | IR → WAT translation |
| ABI | `ABI.hs` | Memory layout constants |

---

## Future: UCM Integration

Once integrated into UCM:

```bash
ucm test --runtime=wasm
ucm test --compare-runtimes=native,wasm
```

Automatic verification across entire Unison test corpus.
