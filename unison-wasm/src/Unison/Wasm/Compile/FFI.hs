-- | Foreign Function Interface handling.
--
-- This module handles FFI for WASM compilation:
-- * Collecting foreign function calls from ANF terms
-- * Generating WASM imports for foreign functions
-- * Debug builtin (Debug.trace, Debug.watch) imports
module Unison.Wasm.Compile.FFI
  ( -- * Import Name Generation
    foreignFuncToImportName,

    -- * Foreign Function Lookup
    builtinNameToForeignFuncMap,
    builtinNameToForeignFunc,

    -- * Collecting Foreign Calls
    collectForeignCalls,
    collectForeignCallsFromGroups,
    collectForeignCallsFromSuperGroup,
    collectForeignCallsFromSuperNormal,

    -- * Generating Imports
    foreignFuncsToImports,
    foreignFuncSignature,

    -- * Debug Builtins
    debugBuiltinNames,
    collectDebugBuiltins,
    collectDebugBuiltinsFromGroups,
    collectDebugBuiltinsFromSuperGroup,
    collectDebugBuiltinsFromSuperNormal,
    debugBuiltinsToImports,
  )
where

import Data.List (groupBy, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (maybeToList)
import Data.Text (Text)
import Data.Text qualified as Text
import Unison.ABT.Normalized qualified as ABTN
import Unison.Reference (Reference)
import Unison.Reference qualified as Reference
import Unison.Runtime.ANF
  ( ANormal,
    Branched (..),
    Func (..),
    SuperGroup (..),
    SuperNormal (..),
    pattern TApp,
    pattern TFOp,
    pattern THnd,
    pattern TLets,
    pattern TMatch,
    pattern TPrm,
    pattern TShift,
    pattern TKon,
  )
import Unison.Runtime.ANF.POp (POp (..))
import Unison.Runtime.Foreign.Function.Type (ForeignFunc (..), foreignFuncBuiltinName)
import Unison.Util.EnumContainers qualified as EC
import Unison.Var (Var)
import Unison.Wasm.Emit (WatImport (..), WatImportKind (..), WatValType (..))

--------------------------------------------------------------------------------
-- Import Name Generation
--------------------------------------------------------------------------------

-- | Convert a ForeignFunc to a WASM import function name.
-- Dots and special chars are replaced with underscores to be WASM-compatible.
foreignFuncToImportName :: ForeignFunc -> String
foreignFuncToImportName ff =
  Text.unpack $ Text.map sanitize (foreignFuncBuiltinName ff)
  where
    sanitize '.' = '_'
    sanitize c = c

--------------------------------------------------------------------------------
-- Foreign Function Lookup
--------------------------------------------------------------------------------

-- | Lookup table from builtin name to ForeignFunc.
-- Built once and cached for fast lookup.
builtinNameToForeignFuncMap :: Map Text ForeignFunc
builtinNameToForeignFuncMap =
  Map.fromList [(foreignFuncBuiltinName ff, ff) | ff <- [minBound .. maxBound]]

-- | Look up a builtin name and return the ForeignFunc if it exists.
builtinNameToForeignFunc :: Text -> Maybe ForeignFunc
builtinNameToForeignFunc name = Map.lookup name builtinNameToForeignFuncMap

--------------------------------------------------------------------------------
-- Collecting Foreign Calls
--------------------------------------------------------------------------------

-- | Collect all foreign function calls from an ANormal term.
-- Returns a list of unique ForeignFuncs encountered.
-- Handles both TFOp (FPrim Right) and TApp (FComb Builtin) patterns.
collectForeignCalls :: (Var v) => ANormal Reference v -> [ForeignFunc]
collectForeignCalls = nub . go
  where
    go (TFOp ff _) = [ff]
    -- Also check TApp with Builtin reference that maps to a foreign function
    go (TApp (FComb (Reference.Builtin name)) _) =
      maybeToList (builtinNameToForeignFunc name)
    go (TLets _ _ _ binding body) = go binding ++ go body
    go (TMatch _ branches) = goBranches branches
    go (THnd _ _ _ body) = go body
    go (TShift _ _ body) = go body
    go (TKon _ _) = [] -- TKon just calls a continuation, no nested terms
    go (ABTN.Term _ (ABTN.Abs _ inner)) = go inner -- Unwrap TAbs
    go _ = []

    goBranches (MatchIntegral cases def) =
      concatMap go (map snd $ EC.mapToList cases) ++ maybe [] go def
    goBranches (MatchNumeric _ cases def) =
      concatMap go (map snd $ EC.mapToList cases) ++ maybe [] go def
    goBranches (MatchData _ cases def) =
      -- MatchData has ref, EnumMap CTag ([Mem], e), Maybe e
      concatMap (\(_, (_, body)) -> go body) (EC.mapToList cases)
        ++ maybe [] go def
    goBranches (MatchEmpty) = []
    goBranches (MatchRequest _ _) = [] -- Request handlers are complex, skip for now
    goBranches (MatchText cases def) =
      concatMap go (Map.elems cases) ++ maybe [] go def
    goBranches (MatchSum cases) =
      -- MatchSum has EnumMap Word64 ([Mem], e)
      concatMap (\(_, (_, body)) -> go body) (EC.mapToList cases)

    nub = map head . groupBy (==) . sort

-- | Collect foreign calls from a main SuperGroup and its lifted combinators.
collectForeignCallsFromGroups ::
  (Var v) =>
  SuperGroup Reference v ->
  [(Reference, SuperGroup Reference v)] ->
  [ForeignFunc]
collectForeignCallsFromGroups mainGroup liftedGroups =
  let mainCalls = collectForeignCallsFromSuperGroup mainGroup
      liftedCalls = concatMap (collectForeignCallsFromSuperGroup . snd) liftedGroups
      allCalls = mainCalls ++ liftedCalls
   in nub allCalls
  where
    nub = map head . groupBy (==) . sort

-- | Collect foreign calls from a SuperGroup.
collectForeignCallsFromSuperGroup :: (Var v) => SuperGroup Reference v -> [ForeignFunc]
collectForeignCallsFromSuperGroup (Rec localDefs entry) =
  let entryCalls = collectForeignCallsFromSuperNormal entry
      localCalls = concatMap (collectForeignCallsFromSuperNormal . snd) localDefs
   in entryCalls ++ localCalls

-- | Collect foreign calls from a SuperNormal.
collectForeignCallsFromSuperNormal :: (Var v) => SuperNormal Reference v -> [ForeignFunc]
collectForeignCallsFromSuperNormal (Lambda _ body) = collectForeignCalls body

--------------------------------------------------------------------------------
-- Generating Imports
--------------------------------------------------------------------------------

-- | Generate WatImport declarations for a list of foreign functions.
-- Each foreign function becomes: (import "ffi" "funcName" (func $funcName ...))
foreignFuncsToImports :: [ForeignFunc] -> [WatImport]
foreignFuncsToImports = map toImport
  where
    toImport ff =
      let name = foreignFuncToImportName ff
          -- For now, assume all foreign funcs take i64 args and return i64
          -- TODO: Look up actual signature from ForeignFunc enum
          (params, results) = foreignFuncSignature ff
       in WatImport
            { importModule = "ffi", -- Use unified 'ffi' namespace
              importName = name,
              importKind = ImportFunc name params results
            }

-- | Get the WASM type signature for a foreign function.
-- For MVP, we use a simplified signature: all args as i64, returns i64.
-- A more complete implementation would look up the actual Unison type signature.
foreignFuncSignature :: ForeignFunc -> ([WatValType], [WatValType])
foreignFuncSignature _ff = ([I64], [I64]) -- Simplified: 1 arg, 1 result

--------------------------------------------------------------------------------
-- Debug Builtins
--------------------------------------------------------------------------------

-- | Debug builtins that need FFI imports
debugBuiltinNames :: [Text]
debugBuiltinNames = ["Debug.trace", "Debug.watch"]

-- | Collect debug primitives/builtins that need FFI imports.
-- Collects both TPrm (TRCE, PRNT) and TApp (FComb (Builtin "Debug.trace")) calls.
collectDebugBuiltins :: (Var v) => ANormal Reference v -> [Text]
collectDebugBuiltins = nub . go
  where
    go (TPrm TRCE _) = ["Debug.trace"]
    go (TPrm PRNT _) = ["Debug.watch"]
    go (TApp (FComb (Reference.Builtin name)) _)
      | name `elem` debugBuiltinNames = [name]
    go (TLets _ _ _ binding body) = go binding ++ go body
    go (TMatch _ branches) = goBranches branches
    go (THnd _ _ _ body) = go body
    go (TShift _ _ body) = go body
    go (ABTN.Term _ (ABTN.Abs _ inner)) = go inner
    go _ = []

    goBranches (MatchIntegral cases def) =
      concatMap go (map snd $ EC.mapToList cases) ++ maybe [] go def
    goBranches (MatchNumeric _ cases def) =
      concatMap go (map snd $ EC.mapToList cases) ++ maybe [] go def
    goBranches (MatchData _ cases def) =
      concatMap (\(_, (_, body)) -> go body) (EC.mapToList cases) ++ maybe [] go def
    goBranches MatchEmpty = []
    goBranches (MatchRequest _ _) = []
    goBranches (MatchText cases def) =
      concatMap go (Map.elems cases) ++ maybe [] go def
    goBranches (MatchSum cases) =
      concatMap (\(_, (_, body)) -> go body) (EC.mapToList cases)

    nub = map head . groupBy (==) . sort

-- | Collect debug builtins from a SuperGroup.
collectDebugBuiltinsFromSuperGroup :: (Var v) => SuperGroup Reference v -> [Text]
collectDebugBuiltinsFromSuperGroup (Rec localDefs entry) =
  let entryCalls = collectDebugBuiltinsFromSuperNormal entry
      localCalls = concatMap (collectDebugBuiltinsFromSuperNormal . snd) localDefs
   in entryCalls ++ localCalls

-- | Collect debug builtins from a SuperNormal.
collectDebugBuiltinsFromSuperNormal :: (Var v) => SuperNormal Reference v -> [Text]
collectDebugBuiltinsFromSuperNormal (Lambda _ body) = collectDebugBuiltins body

-- | Collect debug builtins from all groups.
collectDebugBuiltinsFromGroups ::
  (Var v) =>
  SuperGroup Reference v ->
  [(Reference, SuperGroup Reference v)] ->
  [Text]
collectDebugBuiltinsFromGroups mainGroup liftedGroups =
  let mainCalls = collectDebugBuiltinsFromSuperGroup mainGroup
      liftedCalls = concatMap (collectDebugBuiltinsFromSuperGroup . snd) liftedGroups
   in nub (mainCalls ++ liftedCalls)
  where
    nub = map head . groupBy (==) . sort

-- | Generate imports for debug builtins.
debugBuiltinsToImports :: [Text] -> [WatImport]
debugBuiltinsToImports = map toImport
  where
    toImport "Debug.trace" =
      WatImport
        { importModule = "ffi",
          importName = "Debug_trace",
          importKind = ImportFunc "Debug_trace" [I64, I64] [I64] -- (text, val) -> unit
        }
    toImport "Debug.watch" =
      WatImport
        { importModule = "ffi",
          importName = "Debug_watch",
          importKind = ImportFunc "Debug_watch" [I64] [I64] -- text -> text
        }
    toImport name = error $ "debugBuiltinsToImports: unexpected builtin: " ++ Text.unpack name

