-- | Pattern matching compilation.
--
-- This module compiles Unison pattern matching constructs to WASM:
-- * Integral matches (Nat, Int literals)
-- * Data matches (constructors with field bindings)
-- * Request matches (ability handlers)
--
-- To avoid circular dependencies with the main compiler, all functions
-- take a 'BodyCompiler' callback that compiles sub-expressions.
module Unison.Wasm.Compile.Match
  ( -- * Error Type
    CompileError (..),

    -- * Compiler Callback Type
    BodyCompiler,

    -- * Integral Matching
    compileIntegralMatch,

    -- * Data Matching
    compileDataMatch,
    compileWithFieldBindings,
    extractDataFields,
    extractAbsVars,

    -- * Request Matching
    compileRequestBranches,
    compileOperationCases,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32, Word64)
import Unison.ABT.Normalized qualified as ABTN
import Unison.Reference (Reference)
import Unison.Runtime.ANF
  ( ANormal,
    Mem (..),
    pattern TVar,
  )
import Unison.Runtime.TypeTags (CTag, rawTag)
import Unison.Util.EnumContainers qualified as EC
import Unison.Var (Var)
import Unison.Wasm.ABI qualified as ABI
import Unison.Wasm.Compile.Context
  ( CompileCtx (..),
    bindVars,
    lookupVar,
    refToFuncName,
  )
import Unison.Wasm.Emit (WatInstr (..), WatValType (..))

-- | Callback type for compiling body expressions.
-- Takes context and term, returns either error or instructions.
type BodyCompiler v = CompileCtx v -> ANormal Reference v -> Either CompileError [WatInstr]

-- | Compilation error (simplified for this module)
data CompileError
  = UnsupportedConstruct Text
  deriving (Eq, Show)

--------------------------------------------------------------------------------
-- Integral Matching
--------------------------------------------------------------------------------

-- | Compile MatchIntegral/MatchNumeric with full multi-case support
--
-- Supports an arbitrary number of cases using an if-else chain.
-- Each case compares the scrutinee against a value and branches
-- to the appropriate body.
compileIntegralMatch ::
  (Var v) =>
  BodyCompiler v ->
  CompileCtx v ->
  v -> -- Scrutinee variable
  [(Word64, ANormal Reference v)] -> -- Cases: (value, body)
  Maybe (ANormal Reference v) -> -- Default case
  Either CompileError [WatInstr]
-- No cases, just default
compileIntegralMatch compile ctx _ [] (Just body) = compile ctx body
-- No cases, no default - error
compileIntegralMatch _ _ _ [] Nothing =
  Left $ UnsupportedConstruct "MatchIntegral with no cases and no default"
-- Single case with default: simple if-else
compileIntegralMatch compile ctx scrutVar [(caseVal, thenBody)] (Just elseBody) = do
  scrutInstrs <- compile ctx (TVar scrutVar)
  thenInstrs <- compile ctx thenBody
  elseInstrs <- compile ctx elseBody
  pure $
    scrutInstrs
      ++ [I64Const caseVal, I64Eq]
      ++ [If I64 thenInstrs elseInstrs]
-- Single case, no default (must be exhaustive)
compileIntegralMatch compile ctx scrutVar [(caseVal, thenBody)] Nothing = do
  scrutInstrs <- compile ctx (TVar scrutVar)
  thenInstrs <- compile ctx thenBody
  pure $
    scrutInstrs
      ++ [I64Const caseVal, I64Eq]
      ++ [If I64 thenInstrs [Unreachable]]
-- Multiple cases: if-else chain
compileIntegralMatch compile ctx scrutVar cases mDefault = do
  compileIfElseChain compile ctx scrutVar cases mDefault

-- | Compile an if-else chain for multiple integral cases
compileIfElseChain ::
  (Var v) =>
  BodyCompiler v ->
  CompileCtx v ->
  v ->
  [(Word64, ANormal Reference v)] ->
  Maybe (ANormal Reference v) ->
  Either CompileError [WatInstr]
-- Base case: no more cases, use default
compileIfElseChain compile ctx _ [] (Just dflt) = compile ctx dflt
compileIfElseChain _ _ _ [] Nothing = pure [Unreachable]
-- Recursive case: check one case, else check the rest
compileIfElseChain compile ctx scrutVar ((caseVal, body) : rest) mDefault = do
  -- Load scrutinee for comparison
  scrutInstrs <- compile ctx (TVar scrutVar)
  -- Compile this case's body
  thenInstrs <- compile ctx body
  -- Compile the else branch (remaining cases)
  elseInstrs <- compileIfElseChain compile ctx scrutVar rest mDefault
  pure $
    scrutInstrs
      ++ [I64Const caseVal, I64Eq]
      ++ [If I64 thenInstrs elseInstrs]

--------------------------------------------------------------------------------
-- Data Matching with Field Bindings
--------------------------------------------------------------------------------

-- | Compile MatchData with potential field bindings.
--
-- For each case that has fields, we:
-- 1. Check the constructor tag
-- 2. Extract fields from the heap object
-- 3. Bind fields to local variables
-- 4. Execute the case body
compileDataMatch ::
  (Var v) =>
  BodyCompiler v ->
  CompileCtx v ->
  v -> -- Scrutinee variable
  [(CTag, ([Mem], ANormal Reference v))] -> -- Cases with field info
  Maybe (ANormal Reference v) -> -- Default case
  Either CompileError [WatInstr]
compileDataMatch compile ctx scrutVar cases mDefault = do
  compileDataMatchChain compile ctx scrutVar cases mDefault

-- | Build an if-else chain for data matching
compileDataMatchChain ::
  (Var v) =>
  BodyCompiler v ->
  CompileCtx v ->
  v ->
  [(CTag, ([Mem], ANormal Reference v))] ->
  Maybe (ANormal Reference v) ->
  Either CompileError [WatInstr]
-- Base case: no more cases
compileDataMatchChain compile ctx _ [] (Just dflt) = compile ctx dflt
compileDataMatchChain _ _ _ [] Nothing = pure [Unreachable]
-- Recursive case: check one case
compileDataMatchChain compile ctx scrutVar ((tag, (mems, body)) : rest) mDefault = do
  -- Load scrutinee tag (i64) for comparison
  scrutInstrs <- compile ctx (TVar scrutVar)
  let tagVal = rawTag tag

  -- Compile body with field bindings
  bodyInstrs <-
    if null mems
      then compile ctx body
      else compileWithFieldBindings compile ctx scrutVar mems body

  -- Compile else branch
  elseInstrs <- compileDataMatchChain compile ctx scrutVar rest mDefault

  pure $
    scrutInstrs
      ++ [I64Const tagVal, I64Eq]
      ++ [If I64 bodyInstrs elseInstrs]

-- | Compile a case body after extracting and binding fields from a data object.
--
-- The scrutinee is a pointer (i64) to a Data1/Data2/DataG object.
-- We extract each field and bind it to a fresh local variable.
compileWithFieldBindings ::
  (Var v) =>
  BodyCompiler v ->
  CompileCtx v ->
  v -> -- Scrutinee variable (holds pointer to data object)
  [Mem] -> -- Field memory classifications (extracted from ANormal)
  ANormal Reference v -> -- Body (with ABTN.TAbs wrapping field bindings)
  Either CompileError [WatInstr]
compileWithFieldBindings compile ctx scrutVar mems body = do
  -- The body should be wrapped in TAbs nodes that introduce field variables
  -- We need to unwrap it and extract the field variable names
  let (fieldVars, innerBody) = extractAbsVars body

  -- If the number of field variables doesn't match mems, something is wrong
  if length fieldVars /= length mems
    then
      Left $
        UnsupportedConstruct $
          "Field count mismatch: expected "
            <> Text.pack (show (length mems))
            <> " but got "
            <> Text.pack (show (length fieldVars))
    else do
      -- Create context with field bindings
      let fieldBindings = zip fieldVars mems
          newCtx = bindVars fieldBindings ctx

      -- Get the scrutinee as a pointer
      let (scrutIdx, _) = case lookupVar scrutVar ctx of
            Just x -> x
            Nothing -> (-1, UN) -- Will error below
          scrutLocal = "p" ++ show scrutIdx

      -- Generate field extraction code
      extractInstrs <- extractDataFields scrutLocal mems newCtx fieldVars

      -- Compile the inner body with new context
      bodyInstrs <- compile newCtx innerBody

      pure $ extractInstrs ++ bodyInstrs

-- | Extract bound variables from nested TAbs wrappers
extractAbsVars :: (Var v) => ANormal Reference v -> ([v], ANormal Reference v)
extractAbsVars (ABTN.TAbs v rest) =
  let (moreVars, inner) = extractAbsVars rest
   in (v : moreVars, inner)
extractAbsVars other = ([], other)

-- | Generate instructions to extract fields from a data object.
--
-- Uses ABI offsets to load fields as TypedSlots.
extractDataFields ::
  (Var v) =>
  String -> -- Scrutinee local name (holds pointer)
  [Mem] -> -- Field memory classifications
  CompileCtx v -> -- New context with field bindings
  [v] -> -- Field variable names
  Either CompileError [WatInstr]
extractDataFields _ [] _ [] = pure []
extractDataFields scrutLocal (mem : restMems) ctx (fieldVar : restVars) = do
  let numFields = length restMems + 1
      fieldIdx = numFields - 1 - length restMems -- 0-indexed field position

  -- Determine offset based on number of fields (Data1, Data2, DataG)
  let fieldOffset = case numFields of
        1 -> fromIntegral ABI.data1Field0Offset + 8 -- Skip TypeTag
        2
          | fieldIdx == 0 -> fromIntegral ABI.data2Field0Offset + 8
          | otherwise -> fromIntegral ABI.data2Field1Offset + 8
        _ ->
          fromIntegral ABI.dataGFieldsOffset
            + fromIntegral fieldIdx * fromIntegral ABI.typedSlotSize
            + 8

  -- Get the local name for this field
  let (localIdx, _) = case lookupVar fieldVar ctx of
        Just x -> x
        Nothing -> (-1, UN)
      localName = "p" ++ show localIdx

  -- Generate extraction instruction
  -- The scrutinee is an i64 (boxed pointer), so we need to wrap it to i32
  let extractInstr =
        [ LocalGet scrutLocal,
          I32WrapI64, -- Convert i64 to i32 pointer
          case mem of
            UN -> I64Load fieldOffset -- Unboxed: load payload directly
            BX -> I64Load fieldOffset, -- Boxed: load payload (another pointer)
          LocalSet localName
        ]

  restInstrs <- extractDataFields scrutLocal restMems ctx restVars
  pure $ extractInstr ++ restInstrs
extractDataFields _ _ _ _ = pure [] -- Mismatched lengths, shouldn't happen

--------------------------------------------------------------------------------
-- Request Matching (Ability Handlers)
--------------------------------------------------------------------------------

-- | Compile ability request branches for MatchRequest
-- Each branch is (ability_ref, cases_map) where cases_map maps operation tags to handlers
compileRequestBranches ::
  (Var v) =>
  BodyCompiler v ->
  CompileCtx v ->
  String -> -- Scrutinee local name
  [(Reference, EC.EnumMap CTag ([Mem], ANormal Reference v))] -> -- Ability branches
  Either CompileError [WatInstr]
compileRequestBranches _ _ _ [] =
  -- No branches, unhandled ability request
  pure [Unreachable]
compileRequestBranches compile ctx scrutLocal ((ref, casesMap) : rest) = do
  -- Generate code for this ability's operations
  let abilityRef = refToI32 ref
      cases = EC.mapToList casesMap

  -- For MVP: generate if-else chain for operations within this ability
  -- In a full implementation, we'd first check the ability ref, then dispatch on operation
  opCaseInstrs <- compileOperationCases compile ctx scrutLocal cases

  -- Compile remaining abilities
  restInstrs <- compileRequestBranches compile ctx scrutLocal rest

  -- For MVP, we assume all requests are for this ability
  -- Full implementation would extract ability ref from packed tag and compare
  if null rest
    then pure $ [Comment $ "MatchRequest: ability ref " ++ show abilityRef] ++ opCaseInstrs
    else do
      -- If not handled here, try next ability (as else branch)
      pure $ [Comment $ "MatchRequest: ability ref " ++ show abilityRef] ++ opCaseInstrs ++ restInstrs

-- | Compile operation cases within an ability
compileOperationCases ::
  (Var v) =>
  BodyCompiler v ->
  CompileCtx v ->
  String -> -- Scrutinee local name
  [(CTag, ([Mem], ANormal Reference v))] -> -- (operation tag, (args mems, body))
  Either CompileError [WatInstr]
compileOperationCases _ _ _ [] = pure [Unreachable]
compileOperationCases compile ctx scrutLocal [(_tag, (mems, body))] = do
  -- Single case: just compile the body with field bindings
  if null mems
    then compile ctx body
    else do
      -- The body has TAbs wrappers for the operation arguments
      let (fieldVars, innerBody) = extractAbsVars body
      if length fieldVars /= length mems
        then compile ctx body -- Fallback if mismatch
        else do
          let fieldBindings = zip fieldVars mems
              newCtx = bindVars fieldBindings ctx
          -- Generate field extraction code (from request object)
          extractInstrs <- extractDataFields scrutLocal mems newCtx fieldVars
          bodyInstrs <- compile newCtx innerBody
          pure $ extractInstrs ++ bodyInstrs
compileOperationCases compile ctx scrutLocal ((tag, (mems, body)) : rest) = do
  let tagVal = rawTag tag

  -- Compile this operation's body
  thenInstrs <- compileOperationCases compile ctx scrutLocal [(tag, (mems, body))]

  -- Compile remaining operations
  elseInstrs <- compileOperationCases compile ctx scrutLocal rest

  pure
    [ Comment $ "  Operation tag: " ++ show tagVal,
      -- Load operation tag from request object
      LocalGet scrutLocal,
      I32WrapI64,
      I32Load (fromIntegral ABI.enumCtorIdOffset),
      I32Const (fromIntegral tagVal),
      I32Eq,
      If I64 thenInstrs elseInstrs
    ]

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- | Convert a Reference to an i32 (for ability ref comparison)
refToI32 :: Reference -> Word32
refToI32 ref = fromIntegral $ length (refToFuncName ref) `mod` 0x10000

