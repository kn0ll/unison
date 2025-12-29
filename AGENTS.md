# AGENTS.md — unison-wasm

You are a developer working on the `unison-wasm` package, which compiles Unison terms to WebAssembly.

## Documentation

| Doc | Purpose |
|-----|---------|
| [`unison-wasm/docs/README.md`](./unison-wasm/docs/README.md) | Architecture, quick start, project structure |
| [`unison-wasm/docs/ABI.md`](./unison-wasm/docs/ABI.md) | Memory layout specification (the contract) |
| [`unison-wasm/docs/TODO.md`](./unison-wasm/docs/TODO.md) | Deferred items, optimizations, golden traces |

## Quick Commands

```bash
# Run all tests
stack test unison-wasm           # 302 Haskell tests
cd unison-wasm/js && npm test    # 113 JS tests

# Run the demo
cd unison-wasm/demo && npm install && npm run dev
# Open http://localhost:3001

# Compile Unison to WASM
stack exec unison-wasm-poc -- compile myFunc 'x -> ##Nat.+ x 1'
```

## Key Files

| File | Purpose |
|------|---------|
| `src/Unison/Wasm/Compile.hs` | ANormal → WAT compilation |
| `src/Unison/Wasm/Emit.hs` | WAT text emission |
| `src/Unison/Wasm/ABI.hs` | ABI constants (Haskell) |
| `js/src/abi-constants.ts` | ABI constants (TypeScript) |
| `js/src/runtime.ts` | JS runtime for WASM execution |
| `demo/` | Integration demo (Price Calculator) |

## Conventions

- **Haskell tests**: Use EasyTest with `scope "name"` nesting
- **TypeScript tests**: Use `node:test` with strict types
- **ABI changes**: Update `docs/ABI.md` first, then regenerate constants
- **Terminology**: Use `TypeTag` or `ObjTag`, never bare "tag"

## The Unison Codebase

The WASM compiler reads from Unison's existing IR:

| Import | Purpose |
|--------|---------|
| `Unison.Runtime.ANF` | `SuperGroup`, `ANormal` — compilation input |
| `Unison.Runtime.Stack` | `GClosure`, `K` — closure representations |
| `Unison.Runtime.Machine` | Interpreter — behavioral reference |

When in doubt about semantics, check `Machine.hs`.
