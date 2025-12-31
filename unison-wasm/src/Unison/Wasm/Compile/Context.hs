-- | Compilation context and variable binding management.
--
-- This module provides the stateful context used throughout compilation:
-- * Variable bindings (name → local index)
-- * Function name/arity tracking for calls
-- * Local variable declarations
--
-- The context is threaded through the compilation pipeline,
-- accumulating bindings as the compiler descends into terms.
module Unison.Wasm.Compile.Context
  ( -- * Context Type
    CompileCtx (..),
    emptyCtx,

    -- * Variable Binding
    bindVars,
    lookupVar,

    -- * Local Management
    setBaseLocalCount,
    getSaveableLocalCount,

    -- * Yield Point Management (Async FFI)
    allocYieldPoint,
    getYieldPointCount,

    -- * Type Conversion
    memToValType,

    -- * Name Generation
    refToFuncName,
    sanitizeName,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Unison.Hash qualified as Hash
import Unison.Reference (Reference)
import Unison.Reference qualified as Reference
import Unison.Runtime.ANF (Mem (..))
import Unison.Var (Var)
import Unison.Wasm.Emit (WatValType (..))

-- | Compilation context tracking variable bindings and function names
data CompileCtx v = CompileCtx
  { -- | Map from variable to (local index, memory classification)
    ctxVars :: Map v (Int, Mem),
    -- | Next available local index
    ctxNextLocal :: Int,
    -- | Collected local declarations
    ctxLocals :: [(String, WatValType)],
    -- | Current function name (for recursive calls)
    ctxCurrentFunc :: String,
    -- | Map from combinator variable to function name (for mutual recursion)
    ctxFuncNames :: Map v String,
    -- | Map from Reference to function name (for lifted combinators)
    ctxRefNames :: Map Reference String,
    -- | Map from variable to function arity (for PAp creation)
    ctxFuncArities :: Map v Int,
    -- | Map from Reference to function arity (for lifted combinators)
    ctxRefArities :: Map Reference Int,
    -- | Map from Reference to function table index (for call_indirect)
    ctxRefTableIndices :: Map Reference Int,
    -- | Number of locals at function entry (for Push frame saved_count)
    -- This is set at the start of compiling a function and doesn't change
    ctxBaseLocalCount :: Int,
    -- | Current pending args count (for ability frames)
    ctxPendingArgs :: Int,
    -- | Next yield point ID (for async FFI resume dispatch)
    ctxNextYieldPoint :: Int,
    -- | Whether this function has any yield points (async FFI calls)
    ctxHasYieldPoints :: Bool
  }
  deriving (Eq, Show)

-- | Empty compilation context
emptyCtx :: CompileCtx v
emptyCtx =
  CompileCtx
    { ctxVars = Map.empty,
      ctxNextLocal = 0,
      ctxLocals = [],
      ctxCurrentFunc = "",
      ctxFuncNames = Map.empty,
      ctxRefNames = Map.empty,
      ctxFuncArities = Map.empty,
      ctxRefArities = Map.empty,
      ctxRefTableIndices = Map.empty,
      ctxBaseLocalCount = 0,
      ctxPendingArgs = 0,
      ctxNextYieldPoint = 0,
      ctxHasYieldPoints = False
    }

-- | Set the base local count after binding function parameters
-- This should be called after binding params but before compiling the body
setBaseLocalCount :: CompileCtx v -> CompileCtx v
setBaseLocalCount ctx = ctx {ctxBaseLocalCount = ctxNextLocal ctx}

-- | Get the number of locals to save in a Push frame
-- This is current local count minus base (params only, not saved)
getSaveableLocalCount :: CompileCtx v -> Int
getSaveableLocalCount ctx = ctxNextLocal ctx - ctxBaseLocalCount ctx

-- | Allocate a new yield point ID and return (id, updated context)
-- This marks the function as having yield points.
allocYieldPoint :: CompileCtx v -> (Int, CompileCtx v)
allocYieldPoint ctx =
  let yieldId = ctxNextYieldPoint ctx
   in ( yieldId,
        ctx
          { ctxNextYieldPoint = yieldId + 1,
            ctxHasYieldPoints = True
          }
      )

-- | Get the total number of yield points in the current function
getYieldPointCount :: CompileCtx v -> Int
getYieldPointCount = ctxNextYieldPoint

-- | Look up a variable in the context
lookupVar :: (Var v) => v -> CompileCtx v -> Maybe (Int, Mem)
lookupVar v ctx = Map.lookup v (ctxVars ctx)

-- | Bind variables with their memory classifications
bindVars :: (Var v) => [(v, Mem)] -> CompileCtx v -> CompileCtx v
bindVars bindings ctx =
  let indexed = zip bindings [ctxNextLocal ctx ..]
      newVars = Map.fromList [(v, (i, m)) | ((v, m), i) <- indexed]
      -- Use index-based names ("p0", "p1", etc.) to match generated code
      newLocals = [("p" ++ show i, memToValType m) | ((_, m), i) <- indexed]
   in ctx
        { ctxVars = Map.union newVars (ctxVars ctx),
          ctxNextLocal = ctxNextLocal ctx + length bindings,
          ctxLocals = ctxLocals ctx ++ newLocals
        }

-- | Convert memory classification to WASM type
--
-- NOTE: BX (boxed) is currently treated as I64 because the ANF classifier
-- marks many unboxed values as BX. Proper I32 pointers require fixing
-- the ANF output and updating the K-frame implementation.
memToValType :: Mem -> WatValType
memToValType UN = I64 -- Unboxed: 64-bit value
memToValType BX = I64 -- TODO: optimize to I32 for 32-bit pointers

-- | Generate a short function name from a Reference
-- Uses base32hex encoding for hash, truncated for readability
refToFuncName :: Reference -> String
refToFuncName (Reference.Builtin name) = "builtin_" ++ sanitizeName (Text.unpack name)
refToFuncName (Reference.DerivedId (Reference.Id hash _)) =
  -- Use first 8 chars of the base32hex hash for a readable name
  "fn_" ++ take 8 (Text.unpack (Hash.toBase32HexText hash))

-- | Sanitize a string to be a valid WASM identifier
-- Replaces invalid characters with underscores
sanitizeName :: String -> String
sanitizeName = map (\c -> if isValidIdChar c then c else '_')
  where
    isValidIdChar c = c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || c `elem` ['0' .. '9'] || c == '_'

