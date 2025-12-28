-- | SuperGroup → WAT compiler (Phase 3).
--
-- This module compiles Unison's SuperGroup intermediate representation
-- to WebAssembly Text format (WAT). Phase 3 supports:
--
-- * Unboxed arithmetic (Nat, Int, Float operations)
-- * Local variables (TVar)
-- * Let bindings (TLets)
-- * Primitive operations (TPrm)
-- * Static function calls (TApp FComb)
-- * Full multi-case MatchIntegral/MatchNumeric
-- * Boxed values as I32 pointers (BX → I32)
--
-- NOT supported in Phase 3 (deferred):
-- * Heap allocation for sum types (Phase 3.5)
-- * Closures/partial application (Phase 4)
-- * Abilities/handlers (Phase 5)
module Unison.Wasm.Compile
  ( -- * Compilation
    compileGroup,
    compileGroupWithLifted,
    compileSuperNormal,
    CompileError (..),
    CompileResult,

    -- * Context
    CompileCtx (..),
    emptyCtx,
    lookupVar,
    bindVars,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Unison.ABT.Normalized qualified as ABTN
import Unison.Hash qualified as Hash
import Unison.Reference (Reference)
import Unison.Reference qualified as Reference
import Unison.Runtime.ANF
  ( ANormal,
    Branched (..),
    Func (..),
    Lit (..),
    Mem (..),
    SuperGroup (..),
    SuperNormal (..),
    pattern TApp,
    pattern TBLit,
    pattern TLets,
    pattern TLit,
    pattern TMatch,
    pattern TName,
    pattern TPrm,
    pattern TVar,
  )
import Unison.Runtime.ANF.POp (POp (..))
import Unison.Util.EnumContainers qualified as EC
import Unison.Var (Var)
import Unison.Var qualified as Var
import Unison.Wasm.Emit (WatFunction (..), WatInstr (..), WatModule (..), WatValType (..))

-- | Compilation errors
data CompileError
  = -- | Variable not found in context
    UnboundVariable Text
  | -- | Unsupported primitive operation
    UnsupportedPrimOp POp
  | -- | Unsupported construct (Phase limitation)
    UnsupportedConstruct Text
  | -- | Wrong number of arguments for primitive
    WrongArity POp Int Int -- expected, actual
  | -- | Foreign function call not supported
    UnsupportedForeign Text
  deriving (Eq, Show)

-- | Compilation result
type CompileResult a = Either CompileError a

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
    ctxRefNames :: Map Reference String
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
      ctxRefNames = Map.empty
    }

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
-- NOTE: Phase 3 keeps BX = I64 as a workaround.
-- The ANF classifier marks many unboxed values as BX. Proper I32 pointers
-- require heap allocation (Phase 3.5) and fixing the ANF output.
memToValType :: Mem -> WatValType
memToValType UN = I64 -- Unboxed: 64-bit value
memToValType BX = I64 -- TODO(Phase 3.5): change to I32 after heap allocation works

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
    isValidIdChar c = c `elem` ['a'..'z'] || c `elem` ['A'..'Z'] || c `elem` ['0'..'9'] || c == '_'

--------------------------------------------------------------------------------
-- SuperGroup Compilation
--------------------------------------------------------------------------------

-- | Compile a SuperGroup to a WatModule
--
-- The group's entry function becomes the exported function.
-- Local combinator definitions become internal functions.
compileGroup ::
  (Var v) =>
  SuperGroup Reference v ->
  String ->
  CompileResult WatModule
compileGroup (Rec localDefs entry) exportName = do
  -- Build function name map for all local definitions
  let funcNames = Map.fromList [(v, Text.unpack (Var.name v)) | (v, _) <- localDefs]

  -- Compile local definitions (helper functions)
  localFuncs <- mapM (compileLocalDef funcNames exportName) localDefs

  -- Compile the entry function
  entryFunc <- compileSuperNormalWithCtx funcNames exportName entry exportName

  pure
    WatModule
      { moduleMemory = Nothing,  -- Phase 3: no heap needed for pure arithmetic
        moduleGlobals = [],
        moduleFunctions = localFuncs ++ [entryFunc],
        moduleExports = [exportName],
        moduleMemoryExport = Nothing
      }

-- | Compile a SuperGroup along with its lambda-lifted combinators
--
-- This is used when compiling parsed Unison code which may have
-- lambda-lifted functions as separate SuperGroups.
compileGroupWithLifted ::
  (Var v) =>
  SuperGroup Reference v ->
  [(Reference, SuperGroup Reference v)] ->
  String ->
  CompileResult WatModule
compileGroupWithLifted (Rec localDefs entry) liftedGroups exportName = do
  -- Build a map from Reference to function name for all lifted combinators
  let refNames = Map.fromList [(ref, refToFuncName ref) | (ref, _) <- liftedGroups]

  -- Compile lifted combinators first
  liftedFuncs <- concat <$> mapM (compileLiftedGroup refNames) liftedGroups

  -- Build function name map for local definitions in the main group
  let funcNames = Map.fromList [(v, Text.unpack (Var.name v)) | (v, _) <- localDefs]

  -- Compile local definitions from the main group (if any)
  localFuncs <- mapM (compileLocalDefWithRefCtx funcNames refNames exportName) localDefs

  -- Compile the entry function with reference context (so it can call lifted combinators)
  entryFunc <- compileSuperNormalWithRefCtx funcNames refNames exportName entry exportName

  -- Merge: lifted functions + local functions + entry
  pure
    WatModule
      { moduleMemory = Nothing,  -- Phase 3: no heap needed for pure arithmetic
        moduleGlobals = [],
        moduleFunctions = liftedFuncs ++ localFuncs ++ [entryFunc],
        moduleExports = [exportName],
        moduleMemoryExport = Nothing
      }

-- | Compile a lifted combinator SuperGroup
compileLiftedGroup ::
  (Var v) =>
  Map Reference String ->
  (Reference, SuperGroup Reference v) ->
  CompileResult [WatFunction]
compileLiftedGroup refNames (ref, Rec localDefs entry) = do
  let funcName = maybe (refToFuncName ref) id (Map.lookup ref refNames)

  -- Build function name map for local definitions
  let funcNames = Map.fromList [(v, Text.unpack (Var.name v)) | (v, _) <- localDefs]

  -- Compile local definitions
  localFuncs <- mapM (compileLocalDefWithRefCtx funcNames refNames funcName) localDefs

  -- Compile entry with reference context
  entryFunc <- compileSuperNormalWithRefCtx funcNames refNames funcName entry funcName

  pure $ localFuncs ++ [entryFunc]

-- | Compile a local definition with reference context for calling other lifted combinators
compileLocalDefWithRefCtx ::
  (Var v) =>
  Map v String ->
  Map Reference String ->
  String ->
  (v, SuperNormal Reference v) ->
  CompileResult WatFunction
compileLocalDefWithRefCtx funcNames refNames currentFunc (v, sn) = do
  let name = Text.unpack (Var.name v)
  compileSuperNormalWithRefCtx funcNames refNames currentFunc sn name

-- | Compile a SuperNormal with reference context (for lifted combinators)
compileSuperNormalWithRefCtx ::
  (Var v) =>
  Map v String ->
  Map Reference String ->
  String ->
  SuperNormal Reference v ->
  String ->
  CompileResult WatFunction
compileSuperNormalWithRefCtx funcNames refNames currentFunc (Lambda mems body) name = do
  -- Extract parameter variables and get the inner body
  let (paramVars, innerBody) = unabss body
      baseCtx = emptyCtx
        { ctxCurrentFunc = currentFunc,
          ctxFuncNames = funcNames,
          ctxRefNames = refNames
        }
      -- Only bind as many parameters as we have conventions for
      ctx = bindVars (zip (take (length mems) paramVars) mems) baseCtx

  -- Compile the inner body
  (bodyInstrs, finalCtx) <- compileANormalWithCtx ctx innerBody

  let funcParams = [("p" ++ show i, I64) | i <- [0 .. length mems - 1]]
      funcLocals' = drop (length mems) (ctxLocals finalCtx)
      funcResults = [I64]

  pure
    WatFunction
      { funcName = name,
        funcParams = funcParams,
        funcLocals = funcLocals',
        funcResults = funcResults,
        funcBody = bodyInstrs
      }

-- | Compile a local definition from the group
compileLocalDef ::
  (Var v) =>
  Map v String ->
  String ->
  (v, SuperNormal Reference v) ->
  CompileResult WatFunction
compileLocalDef funcNames currentFunc (v, sn) = do
  let funcName = Text.unpack (Var.name v)
  compileSuperNormalWithCtx funcNames currentFunc sn funcName

-- | Compile a SuperNormal to a WatFunction (legacy, uses empty context)
compileSuperNormal ::
  (Var v) =>
  SuperNormal Reference v ->
  String ->
  CompileResult WatFunction
compileSuperNormal = compileSuperNormalWithCtx Map.empty ""

-- | Compile a SuperNormal to a WatFunction with function context
compileSuperNormalWithCtx ::
  (Var v) =>
  Map v String ->
  String ->
  SuperNormal Reference v ->
  String ->
  CompileResult WatFunction
compileSuperNormalWithCtx funcNames _currentFunc (Lambda mems body) name = do
  -- Extract parameter variables from the body and get the inner body
  let (paramVars, innerBody) = unabss body
      baseCtx = emptyCtx { ctxCurrentFunc = name, ctxFuncNames = funcNames }
      -- Only bind as many parameters as we have conventions for
      ctx = bindVars (zip (take (length mems) paramVars) mems) baseCtx

  -- Compile the inner body (after stripping TAbs wrappers), collecting locals
  (bodyInstrs, finalCtx) <- compileANormalWithCtx ctx innerBody

  let funcParams = [("p" ++ show i, I64) | i <- [0 .. length mems - 1]]
      -- Locals are all variables bound after the parameters
      funcLocals' = drop (length mems) (ctxLocals finalCtx)
      funcResults = [I64] -- Phase 3: always returns i64

  pure
    WatFunction
      { funcName = name,
        funcParams = funcParams,
        funcLocals = funcLocals',
        funcResults = funcResults,
        funcBody = bodyInstrs
      }

-- | Unwrap nested TAbs to get variable bindings and inner term
unabss :: (Var v) => ANormal Reference v -> ([v], ANormal Reference v)
unabss (ABTN.TAbs v (unabss -> (vs, bd))) = (v : vs, bd)
unabss bd = ([], bd)

--------------------------------------------------------------------------------
-- ANormal Compilation
--------------------------------------------------------------------------------

-- | Compile an ANormal term to WASM instructions (returns updated context for locals)
compileANormalWithCtx ::
  (Var v) =>
  CompileCtx v ->
  ANormal Reference v ->
  CompileResult ([WatInstr], CompileCtx v)
compileANormalWithCtx ctx term = do
  instrs <- compileANormal ctx term
  -- Extract the final context by traversing the term again
  let finalCtx = collectLocals ctx term
  pure (instrs, finalCtx)

-- | Collect all local bindings from an ANormal term
collectLocals :: (Var v) => CompileCtx v -> ANormal Reference v -> CompileCtx v
collectLocals ctx (TLets _ letVars mems _ body) =
  let ctx' = bindVars (zip letVars mems) ctx
   in collectLocals ctx' body
collectLocals ctx (TMatch _ (MatchIntegral cases defaultCase)) =
  -- Collect from all branches
  let ctxFromCases = foldr (\(_, branch) c -> collectLocals c branch) ctx (EC.mapToList cases)
   in case defaultCase of
        Just defBody -> collectLocals ctxFromCases defBody
        Nothing -> ctxFromCases
collectLocals ctx (TMatch _ (MatchNumeric _ref cases defaultCase)) =
  -- Collect from all branches (same as MatchIntegral)
  let ctxFromCases = foldr (\(_, branch) c -> collectLocals c branch) ctx (EC.mapToList cases)
   in case defaultCase of
        Just defBody -> collectLocals ctxFromCases defBody
        Nothing -> ctxFromCases
collectLocals ctx _ = ctx

-- | Compile an ANormal term to WASM instructions
compileANormal ::
  (Var v) =>
  CompileCtx v ->
  ANormal Reference v ->
  CompileResult [WatInstr]
-- Let binding: evaluate binding, store in local, continue with body
compileANormal ctx (TLets _direct letVars mems binding body) = do
  -- Compile the binding expression
  bindingInstrs <- compileANormal ctx binding

  -- Extend context with new variables
  let ctx' = bindVars (zip letVars mems) ctx

  -- Get the local indices for storing results
  let storeInstrs = case letVars of
        (v : _) -> case lookupVar v ctx' of
          Just (i, _) ->
            -- Store result in local (for single-result expressions)
            [LocalSet ("p" ++ show i)]
          Nothing -> []
        [] -> []

  -- Compile the body
  bodyInstrs <- compileANormal ctx' body

  pure $ bindingInstrs ++ storeInstrs ++ bodyInstrs

-- Variable reference: push value onto stack
compileANormal ctx (TVar v) = do
  case lookupVar v ctx of
    Just (i, _) -> pure [LocalGet ("p" ++ show i)]
    Nothing -> Left $ UnboundVariable (Var.name v)

-- Literal: push constant onto stack
compileANormal _ctx (TLit lit) = do
  compileLit lit

-- Boxed literal: same as TLit for now (Phase 3: heap alloc deferred to Phase 3.5)
compileANormal _ctx (TBLit lit) = do
  compileLit lit

-- Primitive operation
compileANormal ctx (TPrm op args) = do
  -- Compile arguments (push onto stack)
  argInstrs <- concat <$> mapM (compileANormal ctx . TVar) args
  -- Emit primitive
  opInstr <- compilePrimOp op (length args)
  pure $ argInstrs ++ [opInstr]

-- Static function call (FComb) - handle builtins specially
compileANormal ctx (TApp (FComb ref) args) = do
  -- Compile arguments
  argInstrs <- concat <$> mapM (compileANormal ctx . TVar) args
  case ref of
    -- Builtin references: map to primitive operations
    Reference.Builtin name -> do
      -- Try to map builtin to primitive op
      case builtinToPrimOp name (length args) of
        Just opInstr -> pure $ argInstrs ++ [opInstr]
        Nothing ->
          -- Unknown builtin - fall back to function call if we have a name
          if null (ctxCurrentFunc ctx)
            then Left $ UnsupportedConstruct $ "Unknown builtin: " <> name
            else pure $ argInstrs ++ [Call (ctxCurrentFunc ctx)]
    -- Derived reference: look up in refNames for lifted combinators
    Reference.DerivedId _ -> do
      case Map.lookup ref (ctxRefNames ctx) of
        Just funcName -> pure $ argInstrs ++ [Call funcName]
        Nothing ->
          -- Not found in refNames - might be self-recursion
          let funcName = if null (ctxCurrentFunc ctx) then "target" else ctxCurrentFunc ctx
           in pure $ argInstrs ++ [Call funcName]

-- Function variable call (FVar) - call local combinator
compileANormal ctx (TApp (FVar v) args) = do
  -- Look up the function name in the context
  case Map.lookup v (ctxFuncNames ctx) of
    Just funcName -> do
      argInstrs <- concat <$> mapM (compileANormal ctx . TVar) args
      pure $ argInstrs ++ [Call funcName]
    Nothing ->
      Left $ UnsupportedConstruct "FVar to unknown combinator (closures not supported in Phase 3)"

-- Pattern match on integral values (MatchIntegral)
compileANormal ctx (TMatch v (MatchIntegral cases defaultCase)) = do
  compileIntegralMatch ctx v (EC.mapToList cases) defaultCase

-- Pattern match on boxed numeric values (MatchNumeric)
-- Same as MatchIntegral but for boxed data (produced by parser)
compileANormal ctx (TMatch v (MatchNumeric _ref cases defaultCase)) = do
  compileIntegralMatch ctx v (EC.mapToList cases) defaultCase

-- TName: bind a closure (not supported in Phase 3)
compileANormal _ctx (TName _ _ _ _) = do
  Left $ UnsupportedConstruct "TName (closures) not supported in Phase 3"

-- Fallback for unsupported constructs
compileANormal _ctx _term = do
  Left $ UnsupportedConstruct "Unsupported ANormal construct in Phase 3"

--------------------------------------------------------------------------------
-- Pattern Matching (Phase 3: Full multi-case support)
--------------------------------------------------------------------------------

-- | Compile MatchIntegral/MatchNumeric with full multi-case support
--
-- Phase 3 improves on Phase 2 by supporting an arbitrary number of cases
-- using an if-else chain. Each case compares the scrutinee against a value
-- and branches to the appropriate body.
compileIntegralMatch ::
  (Var v) =>
  CompileCtx v ->
  v ->                                   -- Scrutinee variable
  [(Word64, ANormal Reference v)] ->     -- Cases: (value, body)
  Maybe (ANormal Reference v) ->         -- Default case
  CompileResult [WatInstr]

-- No cases, just default
compileIntegralMatch ctx _ [] (Just body) = compileANormal ctx body

-- No cases, no default - error
compileIntegralMatch _ _ [] Nothing =
  Left $ UnsupportedConstruct "MatchIntegral with no cases and no default"

-- Single case with default: simple if-else
compileIntegralMatch ctx scrutVar [(caseVal, thenBody)] (Just elseBody) = do
  scrutInstrs <- compileANormal ctx (TVar scrutVar)
  thenInstrs <- compileANormal ctx thenBody
  elseInstrs <- compileANormal ctx elseBody
  pure $
    scrutInstrs
      ++ [I64Const caseVal, I64Eq]
      ++ [If I64 thenInstrs elseInstrs]

-- Single case, no default (must be exhaustive)
compileIntegralMatch ctx scrutVar [(caseVal, thenBody)] Nothing = do
  scrutInstrs <- compileANormal ctx (TVar scrutVar)
  thenInstrs <- compileANormal ctx thenBody
  pure $
    scrutInstrs
      ++ [I64Const caseVal, I64Eq]
      ++ [If I64 thenInstrs [Unreachable]]

-- Multiple cases: if-else chain
-- We build a nested if-else structure where each condition checks one case value
compileIntegralMatch ctx scrutVar cases mDefault = do
  compileIfElseChain ctx scrutVar cases mDefault

-- | Compile an if-else chain for multiple integral cases
compileIfElseChain ::
  (Var v) =>
  CompileCtx v ->
  v ->
  [(Word64, ANormal Reference v)] ->
  Maybe (ANormal Reference v) ->
  CompileResult [WatInstr]

-- Base case: no more cases, use default
compileIfElseChain ctx _ [] (Just dflt) = compileANormal ctx dflt
compileIfElseChain _ _ [] Nothing = pure [Unreachable]

-- Recursive case: check one case, else check the rest
compileIfElseChain ctx scrutVar ((caseVal, body):rest) mDefault = do
  -- Load scrutinee for comparison
  scrutInstrs <- compileANormal ctx (TVar scrutVar)
  -- Compile this case's body
  thenInstrs <- compileANormal ctx body
  -- Compile the else branch (remaining cases)
  elseInstrs <- compileIfElseChain ctx scrutVar rest mDefault
  pure $
    scrutInstrs
      ++ [I64Const caseVal, I64Eq]
      ++ [If I64 thenInstrs elseInstrs]

--------------------------------------------------------------------------------
-- Literal Compilation
--------------------------------------------------------------------------------

-- | Compile a literal to WASM instructions
compileLit :: Lit Reference -> CompileResult [WatInstr]
compileLit (N n) = pure [I64Const n]
compileLit (I n) = pure [I64Const (fromIntegral n)]
compileLit (F f) = pure [F64Const f]
compileLit (C c) = pure [I64Const (fromIntegral (fromEnum c))]  -- Unicode codepoint as i64
compileLit (T _t) = Left $ UnsupportedConstruct "Text literals require heap allocation (Phase 3.5)"
compileLit (LM _) = Left $ UnsupportedConstruct "Term links require heap allocation (Phase 3.5)"
compileLit (LY _) = Left $ UnsupportedConstruct "Type links require heap allocation (Phase 3.5)"

--------------------------------------------------------------------------------
-- Primitive Operation Compilation
--------------------------------------------------------------------------------

-- | Compile a primitive operation to a WASM instruction
compilePrimOp :: POp -> Int -> CompileResult WatInstr
-- Nat operations
compilePrimOp ADDN 2 = pure I64Add
compilePrimOp SUBN 2 = pure I64Sub
compilePrimOp MULN 2 = pure I64Mul
compilePrimOp DIVN 2 = pure I64DivU
compilePrimOp MODN 2 = pure I64RemU
compilePrimOp INCN 1 = pure I64Add -- Need to push 1 first
compilePrimOp DECN 1 = pure I64Sub -- Need to push 1 first
compilePrimOp LEQN 2 = pure I64LeU
compilePrimOp LESN 2 = pure I64LtU
compilePrimOp EQLN 2 = pure I64Eq
compilePrimOp NEQN 2 = pure I64Ne
-- Int operations
compilePrimOp ADDI 2 = pure I64Add
compilePrimOp SUBI 2 = pure I64Sub
compilePrimOp MULI 2 = pure I64Mul
compilePrimOp DIVI 2 = pure I64DivS
compilePrimOp MODI 2 = pure I64RemS
compilePrimOp LEQI 2 = pure I64LeS
compilePrimOp LESI 2 = pure I64LtS
compilePrimOp EQLI 2 = pure I64Eq
compilePrimOp NEQI 2 = pure I64Ne
compilePrimOp NEGI 1 = pure I64Sub  -- Uses 0 - x pattern
-- Float operations
compilePrimOp ADDF 2 = pure F64Add
compilePrimOp SUBF 2 = pure F64Sub
compilePrimOp MULF 2 = pure F64Mul
compilePrimOp DIVF 2 = pure F64Div
compilePrimOp LEQF 2 = pure F64Le
compilePrimOp LESF 2 = pure F64Lt
compilePrimOp EQLF 2 = pure F64Eq
-- Unsupported operations
compilePrimOp op _n = Left $ UnsupportedPrimOp op

--------------------------------------------------------------------------------
-- Builtin Reference Mapping
--------------------------------------------------------------------------------

-- | Map builtin reference names to WASM instructions
-- This handles the case where parsed Unison code calls builtins via FComb
-- rather than using TPrm directly.
builtinToPrimOp :: Text -> Int -> Maybe WatInstr
-- Nat operations (the ## prefix is stripped by the parser)
builtinToPrimOp "Nat.+" 2 = Just I64Add
builtinToPrimOp "Nat.sub" 2 = Just I64Sub
builtinToPrimOp "Nat.*" 2 = Just I64Mul
builtinToPrimOp "Nat./" 2 = Just I64DivU
builtinToPrimOp "Nat.mod" 2 = Just I64RemU
builtinToPrimOp "Nat.<=" 2 = Just I64LeU
builtinToPrimOp "Nat.<" 2 = Just I64LtU
builtinToPrimOp "Nat.==" 2 = Just I64Eq
builtinToPrimOp "Universal.==" 2 = Just I64Eq
-- Int operations
builtinToPrimOp "Int.+" 2 = Just I64Add
builtinToPrimOp "Int.-" 2 = Just I64Sub
builtinToPrimOp "Int.*" 2 = Just I64Mul
builtinToPrimOp "Int./" 2 = Just I64DivS
builtinToPrimOp "Int.mod" 2 = Just I64RemS
builtinToPrimOp "Int.<=" 2 = Just I64LeS
builtinToPrimOp "Int.<" 2 = Just I64LtS
builtinToPrimOp "Int.==" 2 = Just I64Eq
-- Float operations
builtinToPrimOp "Float.+" 2 = Just F64Add
builtinToPrimOp "Float.-" 2 = Just F64Sub
builtinToPrimOp "Float.*" 2 = Just F64Mul
builtinToPrimOp "Float./" 2 = Just F64Div
builtinToPrimOp "Float.<=" 2 = Just F64Le
builtinToPrimOp "Float.<" 2 = Just F64Lt
builtinToPrimOp "Float.==" 2 = Just F64Eq
-- Unknown builtin
builtinToPrimOp _ _ = Nothing
