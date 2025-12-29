# Codebase Integration — Implementation Plan

This document describes how to add codebase-aware compilation to `unison-wasm`, enabling the compiler to look up terms by name/hash and resolve transitive dependencies.

---

## Goal

Enable this workflow:

```bash
# Current (v0.1.0) — inline expressions only
stack exec unison-wasm-poc -- compile myFunc 'x -> ##Nat.+ x 1'

# With codebase integration — look up from .unison codebase
stack exec unison-wasm-poc -- compile --codebase ~/.unison myProject.calculateTotal
```

The compiler will:
1. Open a Unison codebase (SQLite database)
2. Resolve `myProject.calculateTotal` to a `Reference`
3. Load the term and all its dependencies
4. Compile everything to a single WASM module

---

## Architecture

### New Module: `Unison.Wasm.Codebase`

```
unison-wasm/src/Unison/Wasm/Codebase.hs
```

This module provides the bridge between codebase access and WASM compilation.

```haskell
module Unison.Wasm.Codebase
  ( compileFromCodebase
  , CompileTarget(..)
  , CodebaseError(..)
  ) where

-- | What to compile
data CompileTarget
  = ByName Text           -- ^ e.g. "myProject.calculateTotal"
  | ByHash ShortHash      -- ^ e.g. "#abc123"

-- | Possible failures
data CodebaseError
  = TermNotFound CompileTarget
  | AmbiguousName Text [Reference]
  | CodebaseMissing FilePath
  | DependencyMissing Reference
  deriving (Show)

-- | Main entry point
compileFromCodebase
  :: FilePath           -- ^ Path to .unison codebase
  -> CompileTarget      -- ^ What to compile
  -> Text               -- ^ Export name
  -> IO (Either CodebaseError WasmModule)
```

---

## Implementation Steps

### Phase 1: Codebase Access

**File:** `src/Unison/Wasm/Codebase.hs`

#### Step 1.1: Open codebase

Use existing infrastructure to open a codebase:

```haskell
import Unison.Codebase qualified as Codebase
import Unison.Codebase.Init qualified as Codebase
import Unison.Codebase.SqliteCodebase qualified as SC

openCodebase :: FilePath -> IO (Either CodebaseError (Codebase IO Symbol Ann))
openCodebase path = do
  result <- Codebase.openCodebase SC.init "unison-wasm" path
  case result of
    Left _ -> pure $ Left (CodebaseMissing path)
    Right (codebase, _) -> pure $ Right codebase
```

#### Step 1.2: Resolve name to Reference

Use `Names` lookup (similar to `TermResolution.hs`):

```haskell
import Unison.HashQualified qualified as HQ
import Unison.Names qualified as Names
import Unison.NamesWithHistory qualified as Names

resolveName
  :: Codebase IO Symbol Ann
  -> Text
  -> IO (Either CodebaseError Reference)
resolveName codebase nameText = do
  -- Get names from the default branch
  names <- getProjectNames codebase
  let hqName = HQ.NameOnly (Name.unsafeParseText nameText)
      refs = Names.lookupHQTerm Names.IncludeSuffixes hqName names
  case toList refs of
    [] -> pure $ Left (TermNotFound (ByName nameText))
    [Referent.Ref ref] -> pure $ Right ref
    multiple -> pure $ Left (AmbiguousName nameText (mapMaybe toRef multiple))
  where
    toRef (Referent.Ref r) = Just r
    toRef _ = Nothing
```

### Phase 2: Dependency Resolution

**Key insight:** The runtime already has `recursiveTermDeps` in `Interface.hs`. We need similar logic.

#### Step 2.1: Create CodeLookup from codebase

Reuse `codebaseToCodeLookup` from `Unison.Codebase.Execute`:

```haskell
import Unison.Codebase.Execute (codebaseToCodeLookup)
import Unison.Codebase.CodeLookup (CodeLookup, transitiveDependencies)

getCodeLookup :: Codebase IO Symbol Ann -> CodeLookup Symbol IO Ann
getCodeLookup = codebaseToCodeLookup
```

#### Step 2.2: Collect transitive dependencies

```haskell
import Unison.Reference qualified as Reference

collectDependencies
  :: CodeLookup Symbol IO Ann
  -> Reference
  -> IO (Set Reference.Id)
collectDependencies codeLookup ref = case ref of
  Reference.Builtin _ -> pure Set.empty  -- Builtins handled separately
  Reference.DerivedId refId ->
    transitiveDependencies codeLookup Set.empty refId
```

#### Step 2.3: Load all terms

```haskell
loadTerms
  :: CodeLookup Symbol IO Ann
  -> Set Reference.Id
  -> IO (Map Reference (Term Symbol Ann))
loadTerms codeLookup refIds = do
  pairs <- forM (toList refIds) $ \refId -> do
    mTerm <- getTerm codeLookup refId
    pure $ (Reference.DerivedId refId,) <$> mTerm
  pure $ Map.fromList (catMaybes pairs)
```

### Phase 3: Multi-Term Compilation

**File:** `src/Unison/Wasm/Compile.hs` (modify existing)

#### Step 3.1: Convert terms to SuperGroups

```haskell
termsToSuperGroups
  :: Map Reference (Term Symbol Ann)
  -> Map Reference (SuperGroup Reference Symbol)
termsToSuperGroups terms = Map.mapWithKey toSuperGroup terms
  where
    toSuperGroup _ref term =
      let (mainTerm, _, _, ctx, _) =
            lamLift mempty
              . splitPatterns builtinDataSpec
              . unannotate
              $ term
      in superNormalize mainTerm
      -- Note: ctx contains lifted lambdas that also need compilation
```

#### Step 3.2: Compile all SuperGroups

Add to `Compile.hs`:

```haskell
compileMultiple
  :: Map Reference (SuperGroup Reference Symbol)
  -> Reference           -- ^ Entry point
  -> Text                -- ^ Export name
  -> Either CompileError WasmModule
compileMultiple groups entryRef exportName = do
  -- Compile each group
  compiledFuncs <- traverse compileGroup (Map.toList groups)
  -- Emit module with entry point exported
  emitMultiModule compiledFuncs entryRef exportName
```

### Phase 4: CLI Integration

**File:** `app/Main.hs`

Add new command:

```haskell
main = do
  args <- getArgs
  case args of
    -- Existing commands...

    ["compile-term", "--codebase", cbPath, name] -> do
      result <- compileFromCodebase cbPath (ByName (Text.pack name)) (Text.pack name)
      case result of
        Left err -> die $ show err
        Right wasmModule -> putStr (emitModule wasmModule)

    ["compile-term", "--codebase", cbPath, "--hash", hash, name] -> do
      result <- compileFromCodebase cbPath (ByHash (ShortHash.unsafeFromText (Text.pack hash))) (Text.pack name)
      case result of
        Left err -> die $ show err
        Right wasmModule -> putStr (emitModule wasmModule)
```

---

## Module Dependencies

```
                    ┌─────────────────────┐
                    │  unison-wasm CLI    │
                    │  (app/Main.hs)      │
                    └─────────┬───────────┘
                              │
                    ┌─────────▼───────────┐
                    │ Unison.Wasm.Codebase│  ◄── NEW
                    └─────────┬───────────┘
                              │
         ┌────────────────────┼────────────────────┐
         │                    │                    │
┌────────▼────────┐  ┌────────▼────────┐  ┌────────▼────────┐
│ parser-typechecker│ │ unison-runtime │ │ Unison.Wasm.*   │
│ (Codebase,       │ │ (ANF, Interface)│ │ (Compile, Emit) │
│  CodeLookup)     │ │                 │ │                  │
└─────────────────┘  └─────────────────┘  └─────────────────┘
```

### Required Package Dependencies

Add to `unison-wasm.cabal`:

```cabal
build-depends:
    -- Existing...
    , unison-codebase          -- Codebase access
    , unison-codebase-sqlite   -- SQLite backend
    , unison-sqlite            -- Database layer
```

---

## Testing Strategy

All tests are in Haskell using EasyTest, matching the existing `unison-wasm` test patterns.

**File:** `test/Wasm/Codebase.hs`

### Test Harness

We reuse existing patterns from `Unison.Test.Ucm` and `Unison.Test.LSP`:

```haskell
module Unison.Test.Wasm.Codebase where

import EasyTest
import System.IO.Temp qualified as Temp
import Unison.Codebase qualified as Codebase
import Unison.Codebase.Init qualified as CI
import Unison.Codebase.SqliteCodebase qualified as SC
import Unison.Parser.Ann (Ann)
import Unison.Symbol (Symbol)
import Unison.Wasm.Codebase (compileFromCodebase, CompileTarget(..), CodebaseError(..))

-- | Create a temporary codebase, populate it, run action
withTestCodebase
  :: (Codebase.Codebase IO Symbol Ann -> IO a)
  -> IO a
withTestCodebase action = do
  tmp <- Temp.getCanonicalTemporaryDirectory
  tmpDir <- Temp.createTempDirectory tmp "wasm-codebase-test"
  result <- CI.withCreatedCodebase SC.init "wasm-test" tmpDir SC.DontLock action
  case result of
    Left _ -> error "Failed to create test codebase"
    Right a -> pure a

-- | Parse and typecheck Unison source, add to codebase
addSourceToCodebase
  :: Codebase.Codebase IO Symbol Ann
  -> Text  -- ^ Source code
  -> IO ()
addSourceToCodebase codebase src = do
  -- Parse source
  uf <- parseAndTypecheck src
  -- Add definitions to codebase
  Codebase.runTransaction codebase $
    Codebase.addDefsToCodebase codebase uf
```

### Unit Tests

```haskell
test :: Test ()
test = scope "Wasm.Codebase" $ tests
  [ scope "name resolution" testNameResolution
  , scope "dependency collection" testDependencyCollection
  , scope "multi-function compile" testMultiFunctionCompile
  , scope "pricing demo" testPricingDemo
  ]
```

### Test 1: Name Resolution

```haskell
testNameResolution :: Test ()
testNameResolution = scope "resolves term by name" do
  result <- io $ withTestCodebase \codebase -> do
    -- Add a simple term
    addSourceToCodebase codebase
      "increment : Nat -> Nat\n\
      \increment x = x + 1"

    -- Compile by name
    compileFromCodebase codebase (ByName "increment") "increment"

  case result of
    Right wasm -> do
      -- Verify the WASM contains the function
      expect $ "increment" `elem` wasmExports wasm
    Left err -> crash $ "Expected success, got: " ++ show err
```

### Test 2: Dependency Collection

```haskell
testDependencyCollection :: Test ()
testDependencyCollection = scope "resolves transitive dependencies" do
  result <- io $ withTestCodebase \codebase -> do
    -- Add terms with dependencies: quadruple -> double -> (builtin +)
    addSourceToCodebase codebase
      "double : Nat -> Nat\n\
      \double x = x + x\n\
      \\n\
      \quadruple : Nat -> Nat\n\
      \quadruple x = double (double x)"

    -- Compile quadruple - should pull in double
    compileFromCodebase codebase (ByName "quadruple") "quadruple"

  case result of
    Right wasm -> do
      -- Both functions should be in the module
      let exports = wasmExports wasm
      expect $ "quadruple" `elem` exports
      -- 'double' may be internal (not exported) but must exist
      expect $ wasmHasFunction wasm "double"
    Left err -> crash $ "Expected success, got: " ++ show err
```

### Test 3: Multi-Function Compile (Pricing Demo)

This is the key test that validates our demo will work:

```haskell
testPricingDemo :: Test ()
testPricingDemo = scope "compiles pricing.u functions" do
  result <- io $ withTestCodebase \codebase -> do
    -- Add the actual pricing.u content
    addSourceToCodebase codebase pricingSource

    -- Compile the main function
    compileFromCodebase codebase (ByName "calculatePrice") "calculatePrice"

  case result of
    Right wasm -> do
      -- Verify all pricing functions exist
      let exports = wasmExports wasm
      expect $ "calculatePrice" `elem` exports

      -- Execute the WASM and verify results
      rt <- io $ instantiateWasm wasm

      -- Test: 1 item = $10.00 (1000 cents)
      expect $ wasmCall rt "calculatePrice" [1] == 1000

      -- Test: 5 items = $45.00 (10% discount)
      expect $ wasmCall rt "calculatePrice" [5] == 4500

      -- Test: 10 items = $90.00 (10% discount)
      expect $ wasmCall rt "calculatePrice" [10] == 9000

    Left err -> crash $ "Expected success, got: " ++ show err

-- | The actual pricing.u source (from demo/src/pricing.u)
pricingSource :: Text
pricingSource =
  "calculateSubtotal : Nat -> Nat\n\
  \calculateSubtotal quantity = quantity * 1000\n\
  \\n\
  \calculateDiscount : Nat -> Nat\n\
  \calculateDiscount quantity =\n\
  \  subtotal = calculateSubtotal quantity\n\
  \  if quantity >= 5 then subtotal / 10 else 0\n\
  \\n\
  \calculatePrice : Nat -> Nat\n\
  \calculatePrice quantity =\n\
  \  subtotal = calculateSubtotal quantity\n\
  \  discount = calculateDiscount quantity\n\
  \  subtotal - discount"
```

### Test 4: Error Cases

```haskell
testErrorCases :: Test ()
testErrorCases = scope "error handling" $ tests
  [ scope "term not found" do
      result <- io $ withTestCodebase \codebase -> do
        compileFromCodebase codebase (ByName "doesNotExist") "test"
      expect $ result == Left (TermNotFound (ByName "doesNotExist"))

  , scope "ambiguous name" do
      result <- io $ withTestCodebase \codebase -> do
        -- Add two terms with the same unqualified name
        addSourceToCodebase codebase
          "Foo.increment : Nat -> Nat\n\
          \Foo.increment x = x + 1\n\
          \\n\
          \Bar.increment : Nat -> Nat\n\
          \Bar.increment x = x + 2"

        compileFromCodebase codebase (ByName "increment") "increment"

      case result of
        Left (AmbiguousName _ refs) -> expect $ length refs == 2
        _ -> crash "Expected AmbiguousName error"
  ]
```

### WASM Execution Helpers

```haskell
-- | Instantiate compiled WASM for testing
instantiateWasm :: WasmModule -> IO WasmInstance
instantiateWasm wasm = do
  -- Convert to binary
  let wat = emitModule wasm
  binary <- wat2wasm wat
  -- Instantiate with minimal imports
  Wasm.instantiate binary minimalImports

-- | Call a WASM function
wasmCall :: WasmInstance -> Text -> [Int64] -> Int64
wasmCall inst name args =
  Wasm.call inst (Text.unpack name) (map Wasm.I64 args)

-- | Get exported function names
wasmExports :: WasmModule -> [Text]
wasmExports = mapMaybe getExportName . moduleExports

-- | Check if a function exists (exported or internal)
wasmHasFunction :: WasmModule -> Text -> Bool
wasmHasFunction wasm name =
  any ((== name) . funcName) (moduleFunctions wasm)
```
```

---

## Demo Integration

Once codebase integration works, the demo build process changes:

### Before (Current)

```
demo/src/pricing.u  →  (hand-written WAT)  →  pricing.wasm
                        ↑
                        Fallback because compiler
                        can't compile .u files
```

### After (With Codebase Integration)

```
demo/src/pricing.u  →  (typecheck)  →  Codebase  →  compileFromCodebase  →  pricing.wasm
                                                     ↑
                                                     Real compiler output
```

### Updated Build Script

The `build-wasm.sh` becomes a thin wrapper that calls our Haskell tooling:

```bash
#!/bin/bash
# demo/build-wasm.sh (simplified)

# Compile pricing.u to WASM via codebase integration
stack exec unison-wasm-poc -- compile-from-source \
  --source src/pricing.u \
  --entry calculatePrice \
  --output dist/pricing.wat

# Convert to binary
wat2wasm dist/pricing.wat -o dist/pricing.wasm
```

Or even simpler — add a CLI command that handles everything:

```bash
stack exec unison-wasm-poc -- compile-file src/pricing.u \
  --entries calculatePrice,calculateDiscount,calculateSubtotal \
  --output dist/pricing.wasm
```

### New CLI Command

Add to `app/Main.hs`:

```haskell
["compile-from-source", "--source", srcPath, "--entry", entryName, "--output", outPath] -> do
  -- 1. Create temporary codebase
  withTemporaryCodebase \codebase -> do
    -- 2. Parse and typecheck source file
    src <- Text.readFile srcPath
    uf <- parseAndTypecheck src

    -- 3. Add to codebase
    Codebase.runTransaction codebase $
      Codebase.addDefsToCodebase codebase uf

    -- 4. Compile from codebase
    result <- compileFromCodebase codebase (ByName entryName) entryName
    case result of
      Left err -> die $ show err
      Right wasm -> do
        -- 5. Write output
        let wat = emitModule wasm
        Text.writeFile outPath wat
```

This approach:
1. **Validates the full pipeline** — same code path as codebase lookup
2. **No hand-written WAT** — everything goes through the compiler
3. **Tests real integration** — parsing, typechecking, ANF, WASM emission

---

## Open Questions

### Q1: How to handle builtins?

Builtins like `Nat.+` are `Reference.Builtin`. They don't have source code — they're implemented as WASM primitives or foreign calls.

**Approach:** Skip builtins in dependency collection; the compiler already handles them via `compileForeign`.

### Q2: What about type declarations?

Data types and effects need their constructor tags. The compiler needs `DataSpec` information.

**Approach:** Use `builtinDataSpec` for builtins. For user-defined types, extract from codebase and merge:

```haskell
getUserDataSpec :: CodeLookup Symbol IO Ann -> Set Reference -> IO DataSpec
getUserDataSpec cl typeRefs = do
  decls <- forM (toList typeRefs) $ \ref ->
    case ref of
      Reference.DerivedId refId -> getTypeDeclaration cl refId
      _ -> pure Nothing
  pure $ buildDataSpec (catMaybes decls) <> builtinDataSpec
```

### Q3: How to handle effects/abilities?

Effects in the codebase may have handlers. For WASM compilation:

- **Pure abilities (State, Reader):** Compile handlers inline
- **IO-like abilities:** Map to foreign calls, handled by JS runtime

**For v1.0:** Focus on pure functions first. Effects that require foreign calls already work via the existing `ForeignCall` mechanism.

---

## Milestones

| Milestone | Description | Deliverable |
|-----------|-------------|-------------|
| M1 | Open codebase, resolve single name | `resolveName` function works |
| M2 | Load term + dependencies | `collectDependencies` returns correct set |
| M3 | Compile single term from codebase | CLI `compile-term` works for simple functions |
| M4 | Compile with dependencies | Multi-function WASM modules work |
| M5 | Handle user-defined types | Constructor patterns work |

---

## References

| File | Purpose |
|------|---------|
| `Unison.Codebase.Execute` | `codebaseToCodeLookup` — how runtime loads code |
| `Unison.Codebase.CodeLookup` | `transitiveDependencies` — dependency traversal |
| `Unison.Runtime.Interface` | `recursiveTermDeps` — another dependency approach |
| `Unison.Codebase.Editor.HandleInput.TermResolution` | Name → Reference resolution |
| `Unison.Wasm.Compile` | Current single-function compiler |

