{-# OPTIONS_GHC -Wno-incomplete-uni-patterns -fmax-pmcheck-models=100 #-}

-- | SuperGroup → WAT compiler.
--
-- This module compiles Unison's SuperGroup intermediate representation
-- to WebAssembly Text format (WAT).
--
-- Supported:
-- * Unboxed arithmetic (Nat, Int, Float operations)
-- * Local variables (TVar)
-- * Let bindings (TLets)
-- * Primitive operations (TPrm)
-- * Static function calls (TApp FComb)
-- * Full multi-case pattern matching (MatchIntegral/MatchNumeric/MatchData for enums)
-- * Closures and partial application (TName → PAp allocation, call_indirect)
-- * Sum types / enums (FCon, MatchData)
--
-- NOT YET supported (Phase 6+):
-- * Async foreign calls to JS host
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
    setBaseLocalCount,
    getSaveableLocalCount,

    -- * Foreign Calls (Phase 6)
    foreignFuncToImportName,
    collectForeignCalls,
    foreignFuncsToImports,
  )
where

import Data.ByteString qualified as BS
import Data.List (groupBy, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32, Word64)
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
    pattern TFOp,
    pattern THnd,
    pattern TKon,
    pattern TLets,
    pattern TLit,
    pattern TMatch,
    pattern TName,
    pattern TPrm,
    pattern TShift,
    pattern TVar,
  )
import Unison.Runtime.ANF.POp (POp (..))
import Unison.Runtime.Foreign.Function.Type (ForeignFunc (..), foreignFuncBuiltinName)
import Unison.Runtime.TypeTags (CTag, rawTag)
import Unison.Util.EnumContainers qualified as EC
import Unison.Var (Var)
import Unison.Var qualified as Var
import Unison.Wasm.ABI qualified as ABI
import Unison.Wasm.Compile.Primitives qualified as P
import Unison.Wasm.Compile.Runtime qualified as Runtime
import Unison.Wasm.Emit (WatFunction (..), WatImport (..), WatImportKind (..), WatInstr (..), WatModule (..), WatValType (..))

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
    ctxPendingArgs :: Int
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
      ctxPendingArgs = 0
    }

-- | Set the base local count after binding function parameters
-- This should be called after binding params but before compiling the body
setBaseLocalCount :: CompileCtx v -> CompileCtx v
setBaseLocalCount ctx = ctx { ctxBaseLocalCount = ctxNextLocal ctx }

-- | Get the number of locals to save in a Push frame
-- This is current local count minus base (params only, not saved)
getSaveableLocalCount :: CompileCtx v -> Int
getSaveableLocalCount ctx = ctxNextLocal ctx - ctxBaseLocalCount ctx

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
memToValType BX = I64 -- TODO(Phase 5): change to I32 for proper pointers

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

  let allFuncs = Runtime.runtimeFunctions ++ localFuncs ++ [entryFunc]
      -- Build function table with all user functions (not runtime helpers)
      tableFuncs = map funcName (localFuncs ++ [entryFunc])

  pure
    WatModule
      { moduleMemory = Just 1, -- 1 page (64KB) for heap
        moduleGlobals = Runtime.runtimeGlobals,
        moduleFunctions = allFuncs,
        moduleExports = [exportName],
        moduleMemoryExport = Just "memory",
        moduleFuncTypes = Runtime.runtimeFuncTypes,
        moduleTableFuncs = tableFuncs,
        moduleImports = []  -- No foreign calls in this mode
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

  -- Build a map from Reference to arity for all lifted combinators
  let refArities = Map.fromList [(ref, superGroupArity sg) | (ref, sg) <- liftedGroups]

  -- Build a map from Reference to table index
  -- Table order: liftedFuncs, then localFuncs, then entryFunc
  -- Each lifted group may produce multiple functions, but we only index the entry
  let refTableIndices = Map.fromList $ zip (map fst liftedGroups) [0..]

  -- Compile lifted combinators first
  liftedFuncs <- concat <$> mapM (compileLiftedGroup refNames refArities refTableIndices) liftedGroups

  -- Build function name map for local definitions in the main group
  let funcNames = Map.fromList [(v, Text.unpack (Var.name v)) | (v, _) <- localDefs]

  -- Build arity map for local definitions
  let funcArities = Map.fromList [(v, superNormalArity sn) | (v, sn) <- localDefs]

  -- Compile local definitions from the main group (if any)
  localFuncs <- mapM (compileLocalDefWithRefCtx funcNames funcArities refNames refArities refTableIndices exportName) localDefs

  -- Compile the entry function with reference context (so it can call lifted combinators)
  entryFunc <- compileSuperNormalWithRefCtx funcNames funcArities refNames refArities refTableIndices exportName entry exportName

  -- Merge: runtime + lifted functions + local functions + entry
  let allFuncs = Runtime.runtimeFunctions ++ liftedFuncs ++ localFuncs ++ [entryFunc]
      -- Build function table with all user functions (for call_indirect)
      userFuncs = liftedFuncs ++ localFuncs ++ [entryFunc]
      tableFuncs = map funcName userFuncs

  -- Collect foreign calls from all SuperGroups
  let allForeignCalls = collectForeignCallsFromGroups (Rec localDefs entry) liftedGroups
      imports = foreignFuncsToImports allForeignCalls

  pure
    WatModule
      { moduleMemory = Just 1, -- 1 page (64KB) for heap
        moduleGlobals = Runtime.runtimeGlobals,
        moduleFunctions = allFuncs,
        moduleExports = exportName : Runtime.runtimeExports,  -- Include runtime exports like __resume
        moduleMemoryExport = Just "memory",
        moduleFuncTypes = Runtime.runtimeFuncTypes,
        moduleTableFuncs = tableFuncs,
        moduleImports = imports
      }

-- | Get the arity of a SuperGroup (from its entry point)
superGroupArity :: SuperGroup ref v -> Int
superGroupArity (Rec _ entry) = superNormalArity entry

-- | Get the arity of a SuperNormal (length of conventions list)
superNormalArity :: SuperNormal ref v -> Int
superNormalArity (Lambda mems _) = length mems

-- | Compile a lifted combinator SuperGroup
compileLiftedGroup ::
  (Var v) =>
  Map Reference String ->
  Map Reference Int ->
  Map Reference Int ->  -- table indices
  (Reference, SuperGroup Reference v) ->
  CompileResult [WatFunction]
compileLiftedGroup refNames refArities refTableIndices (ref, Rec localDefs entry) = do
  let funcName = maybe (refToFuncName ref) id (Map.lookup ref refNames)

  -- Build function name map for local definitions
  let funcNames = Map.fromList [(v, Text.unpack (Var.name v)) | (v, _) <- localDefs]

  -- Build arity map for local definitions
  let funcArities = Map.fromList [(v, superNormalArity sn) | (v, sn) <- localDefs]

  -- Compile local definitions
  localFuncs <- mapM (compileLocalDefWithRefCtx funcNames funcArities refNames refArities refTableIndices funcName) localDefs

  -- Compile entry with reference context
  entryFunc <- compileSuperNormalWithRefCtx funcNames funcArities refNames refArities refTableIndices funcName entry funcName

  pure $ localFuncs ++ [entryFunc]

-- | Compile a local definition with reference context for calling other lifted combinators
compileLocalDefWithRefCtx ::
  (Var v) =>
  Map v String ->
  Map v Int ->
  Map Reference String ->
  Map Reference Int ->
  Map Reference Int ->  -- table indices
  String ->
  (v, SuperNormal Reference v) ->
  CompileResult WatFunction
compileLocalDefWithRefCtx funcNames funcArities refNames refArities refTableIndices currentFunc (v, sn) = do
  let name = Text.unpack (Var.name v)
  compileSuperNormalWithRefCtx funcNames funcArities refNames refArities refTableIndices currentFunc sn name

-- | Compile a SuperNormal with reference context (for lifted combinators)
compileSuperNormalWithRefCtx ::
  (Var v) =>
  Map v String ->
  Map v Int ->
  Map Reference String ->
  Map Reference Int ->
  Map Reference Int ->  -- table indices
  String ->
  SuperNormal Reference v ->
  String ->
  CompileResult WatFunction
compileSuperNormalWithRefCtx funcNames funcArities refNames refArities refTableIndices currentFunc (Lambda mems body) name = do
  -- Extract parameter variables and get the inner body
  let (paramVars, innerBody) = unabss body
      baseCtx = emptyCtx
        { ctxCurrentFunc = currentFunc,
          ctxFuncNames = funcNames,
          ctxRefNames = refNames,
          ctxFuncArities = funcArities,
          ctxRefArities = refArities,
          ctxRefTableIndices = refTableIndices
        }
      -- Only bind as many parameters as we have conventions for
      ctx = bindVars (zip (take (length mems) paramVars) mems) baseCtx

  -- Compile the inner body
  (bodyInstrs, finalCtx) <- compileANormalWithCtx ctx innerBody

  let funcParams = [("p" ++ show i, I64) | i <- [0 .. length mems - 1]]
      -- Add runtime helper locals used by various constructs
      helperLocals =
        [ ("__pap_temp", I32)       -- PAp allocation
        , ("__datag_temp", I32)     -- DataG allocation
        , ("__cont_ptr", I32)       -- Continuation pointer (TKon)
        , ("__k_start", I32)        -- TShift: K chain start
        , ("__k_walk", I32)         -- TShift: K walk pointer
        , ("__mark_ptr", I32)       -- TShift: Found Mark frame
        , ("__float_temp", I64)     -- Float operations temp
        , ("__frame_tag", I32)      -- TShift: Frame tag
        , ("__captured_ptr", I32)   -- TShift: Captured object
        , ("__req_ptr", I32)        -- TReq: Request object pointer
        , ("__req_arg0", I64)       -- TReq: First arg temp
        , ("__handler_ptr", I32)    -- TReq: Handler pointer from denv
        ]
      funcLocals' = drop (length mems) (ctxLocals finalCtx) ++ helperLocals
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
      -- Add runtime helper locals used by various constructs
      helperLocals =
        [ ("__pap_temp", I32)       -- PAp allocation
        , ("__datag_temp", I32)     -- DataG allocation
        , ("__cont_ptr", I32)       -- Continuation pointer (TKon)
        , ("__k_start", I32)        -- TShift: K chain start
        , ("__k_walk", I32)         -- TShift: K walk pointer
        , ("__mark_ptr", I32)       -- TShift: Found Mark frame
        , ("__float_temp", I64)     -- Float operations temp
        , ("__frame_tag", I32)      -- TShift: Frame tag
        , ("__captured_ptr", I32)   -- TShift: Captured object
        , ("__req_ptr", I32)        -- TReq: Request object pointer
        , ("__req_arg0", I64)       -- TReq: First arg temp
        , ("__handler_ptr", I32)    -- TReq: Handler pointer from denv
        ]
      -- Locals are all variables bound after the parameters plus helpers
      funcLocals' = drop (length mems) (ctxLocals finalCtx) ++ helperLocals
      funcResults = [I64] -- All functions return i64 (boxed values or unboxed integers)

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
-- THnd: collect from the handler body
collectLocals ctx (THnd _refs _handlerVar _affineHandler body) =
  collectLocals ctx body
-- TShift: bind the continuation variable and collect from body
collectLocals ctx (TShift _ref contVar body) =
  let ctx' = bindVars [(contVar, BX)] ctx
   in collectLocals ctx' body
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
-- Also handles partial application when args.length < arity
compileANormal ctx (TApp (FComb ref) args) = do
  -- Compile arguments
  argInstrs <- concat <$> mapM (compileANormal ctx . TVar) args
  let numArgs = length args
  case ref of
    -- Builtin references: map to primitive operations
    Reference.Builtin name -> do
      -- Try to map builtin to primitive op
      case builtinToPrimOp name numArgs of
        Just opInstrs -> pure $ argInstrs ++ opInstrs
        Nothing ->
          -- Unknown builtin - fall back to function call if we have a name
          if null (ctxCurrentFunc ctx)
            then Left $ UnsupportedConstruct $ "Unknown builtin: " <> name
            else pure $ argInstrs ++ [Call (ctxCurrentFunc ctx)]
    -- Derived reference: look up in refNames for lifted combinators
    Reference.DerivedId _ -> do
      case Map.lookup ref (ctxRefNames ctx) of
        Just funcName -> do
          -- Check if this is a partial application
          case Map.lookup ref (ctxRefArities ctx) of
            Just arity | numArgs < arity ->
              -- Partial application: create a PAp and store args
              -- Use table index for call_indirect
              let tableIdx = Map.lookup ref (ctxRefTableIndices ctx)
              in case tableIdx of
                   Just idx -> do
                     -- Allocate PAp, store captured args, then convert to i64
                     -- Use __pap_temp local (must be declared in the function)
                     let tempName = "__pap_temp"
                     storeInstrs <- storePApArgs ctx tempName 0 args
                     pure $
                       -- Don't use argInstrs - we read from locals in storePApArgs
                       [ I32Const (fromIntegral idx)
                       , I32Const (fromIntegral arity)
                       , I32Const (fromIntegral numArgs)
                       , Call "__alloc_pap"
                       , LocalSet tempName  -- Store PAp pointer
                       ]
                       ++ storeInstrs  -- Store captured args
                       ++ [LocalGet tempName, I64ExtendI32U]  -- Get pointer and extend to i64
                   Nothing ->
                     Left $ UnsupportedConstruct $ "No table index for reference in partial application"
            _ ->
              -- Full application: direct call
              pure $ argInstrs ++ [Call funcName]
        Nothing ->
          -- Not found in refNames - might be self-recursion
          let funcName = if null (ctxCurrentFunc ctx) then "target" else ctxCurrentFunc ctx
           in pure $ argInstrs ++ [Call funcName]

-- Function variable call (FVar) - call local combinator or PAp
compileANormal ctx (TApp (FVar v) args) = do
  -- Look up the function name in the context
  case Map.lookup v (ctxFuncNames ctx) of
    Just funcName -> do
      -- Known combinator - direct call
      argInstrs <- concat <$> mapM (compileANormal ctx . TVar) args
      pure $ argInstrs ++ [Call funcName]
    Nothing ->
      -- Not a known combinator - must be a local variable holding a PAp
      case lookupVar v ctx of
        Just (localIdx, _) -> do
          -- This is a local variable holding a PAp pointer
          -- We need to dynamically dispatch: load captured args + new args, then call_indirect
          argInstrs <- concat <$> mapM (compileANormal ctx . TVar) args
          let numNewArgs = length args
              papLocal = "p" ++ show localIdx
          -- Generate code to invoke the PAp with new arguments
          pure $ compileApplyPAp papLocal numNewArgs argInstrs
        Nothing ->
          Left $ UnboundVariable (Var.name v)

-- Data constructor application (FCon) - create enum/data values
-- Enums (no fields): return the tag as i64
-- Data1 (1 field): allocate heap object
-- Data2 (2 fields): allocate heap object
-- DataG (3+ fields): allocate heap object
compileANormal _ctx (TApp (FCon _ref tag) []) = do
  -- Enum type: just return the constructor tag as i64
  pure [I64Const (rawTag tag)]

compileANormal ctx (TApp (FCon ref tag) [arg1]) = do
  -- Data1: one field
  argInstrs <- compileANormal ctx (TVar arg1)
  let typeRef = refToI32 ref
      ctorId = fromIntegral (rawTag tag) :: Word32
      argTag = getVarTypeTag ctx arg1
  pure $
    [ I32Const typeRef,
      I32Const ctorId,
      I32Const argTag -- field0 TypeTag
    ]
      ++ argInstrs -- field0 value on stack
      ++ [Call "__alloc_data1"]
      ++ P.extendPtrToI64 -- Return as i64

compileANormal ctx (TApp (FCon ref tag) [arg1, arg2]) = do
  -- Data2: two fields
  arg1Instrs <- compileANormal ctx (TVar arg1)
  arg2Instrs <- compileANormal ctx (TVar arg2)
  let typeRef = refToI32 ref
      ctorId = fromIntegral (rawTag tag) :: Word32
      arg1Tag = getVarTypeTag ctx arg1
      arg2Tag = getVarTypeTag ctx arg2
  pure $
    [ I32Const typeRef,
      I32Const ctorId,
      I32Const arg1Tag
    ]
      ++ arg1Instrs
      ++ [I32Const arg2Tag]
      ++ arg2Instrs
      ++ [Call "__alloc_data2"]
      ++ P.extendPtrToI64 -- Return as i64

compileANormal ctx (TApp (FCon ref tag) args) = do
  -- DataG: 3+ fields - allocate then fill
  let numArgs = length args
      typeRef = refToI32 ref
      ctorId = fromIntegral (rawTag tag) :: Word32
  -- First allocate the object
  let allocInstrs =
        [ I32Const typeRef,
          I32Const ctorId,
          I32Const (fromIntegral numArgs),
          Call "__alloc_datag",
          LocalSet "__datag_temp"
        ]
  -- Then store each field
  storeInstrs <- storeDataGFields ctx args 0
  pure $
    allocInstrs
      ++ storeInstrs
      ++ [LocalGet "__datag_temp"]
      ++ P.extendPtrToI64

-- TReq: Ability request (TApp (FReq ref tag) args)
-- Creates a request value and triggers the handler for the ability.
--
-- In the native runtime, this:
-- 1. Packs the request (ability ref + ctor tag + args)
-- 2. Captures the continuation up to the handler's Mark frame
-- 3. Calls the handler with the packed request
--
-- For WASM, we:
-- 1. Create a data object representing the request (ctor_id = tag)
-- 2. Look up the handler in denv
-- 3. Capture the continuation (similar to TShift)
-- 4. Call the handler with the request
compileANormal ctx (TApp (FReq abilityRef tag) args) = do
  let typeRef = refToI32 abilityRef
      ctorId = fromIntegral (rawTag tag) :: Word32
      numArgs = length args

  -- Compile arguments for the request
  argInstrs <- concat <$> mapM (compileANormal ctx . TVar) args

  pure $
    [ Comment $ "TReq: Ability request"
    , Comment $ "  Ability ref: " ++ show typeRef ++ ", ctor: " ++ show ctorId

    -- 1. Create request object (Data with ability ref as type, tag as ctor)
    --    For 0 args, create enum-like object
    --    For 1+ args, create Data1/2/G
    ]
      ++ (if numArgs == 0
            then
              [ I32Const typeRef
              , I32Const ctorId
              , Call "__alloc_enum"
              , LocalSet "__req_ptr"
              ]
            else if numArgs == 1
              then
                argInstrs ++
                [ LocalSet "__req_arg0"  -- Save arg temporarily
                , I32Const typeRef
                , I32Const ctorId
                , I32Const (fromIntegral $ ABI.typeTagToWord8 ABI.typeNat)  -- TypeTag for first arg
                , LocalGet "__req_arg0"
                , Call "__alloc_data1"
                , LocalSet "__req_ptr"
                ]
              else
                -- For 2+ args, use datag (simplified)
                [ I32Const typeRef
                , I32Const ctorId
                , I32Const (fromIntegral numArgs)
                , Call "__alloc_datag"
                , LocalSet "__req_ptr"
                -- TODO: store args into datag
                ])
      ++
      [ Comment "  2. Look up handler in denv"
      , GlobalGet "denv_ptr"
      , I32Const typeRef  -- Ability reference as key
      , Call "__denv_lookup"
      , LocalSet "__handler_ptr"

      -- If handler not found, trap
      , LocalGet "__handler_ptr"
      , I32Eqz
      , IfVoid [Unreachable] []

      , Comment "  3. Capture continuation (similar to TShift)"
      -- Save starting k_ptr
      , GlobalGet "k_ptr"
      , LocalSet "__k_start"

      -- Walk K to find the Mark frame for this ability
      , GlobalGet "k_ptr"
      , LocalSet "__k_walk"

      , Block "req_found"
          [ Loop "req_walk"
              [ LocalGet "__k_walk"
              , I32Eqz
              , IfVoid [Unreachable] []  -- Fell off stack

              , LocalGet "__k_walk"
              , I32Load8U (fromIntegral ABI.kPushFrameTagOffset)
              , LocalSet "__frame_tag"

              , LocalGet "__frame_tag"
              , I32Const (fromIntegral $ ABI.frameTagToWord8 ABI.frameMark)
              , I32Eq
              , IfVoid
                  [ LocalGet "__k_walk"
                  , I32Load (fromIntegral ABI.kMarkAbilityRefOffset)
                  , I32Const typeRef
                  , I32Eq
                  , IfVoid
                      [ LocalGet "__k_walk"
                      , LocalSet "__mark_ptr"
                      , Br "req_found"
                      ]
                      [ LocalGet "__k_walk"
                      , I32Load (fromIntegral ABI.kMarkNextKOffset)
                      , LocalSet "__k_walk"
                      , Br "req_walk"
                      ]
                  ]
                  [ LocalGet "__k_walk"
                  , I32Load (fromIntegral ABI.kPushNextKOffset)
                  , LocalSet "__k_walk"
                  , Br "req_walk"
                  ]
              ]
          ]

      , Comment "  4. Create Captured object"
      , LocalGet "__k_start"
      , I32Const 0  -- pending_args
      , I32Const 0  -- slot_count (MVP)
      , Call "__alloc_captured"
      , LocalSet "__captured_ptr"

      , Comment "  5. Restore denv from Mark frame"
      , LocalGet "__mark_ptr"
      , I32Load (fromIntegral ABI.kMarkLocalCountOffset)
      , GlobalSet "denv_ptr"

      , Comment "  6. Pop K stack to Mark's next"
      , LocalGet "__mark_ptr"
      , I32Load (fromIntegral ABI.kMarkNextKOffset)
      , GlobalSet "k_ptr"

      , Comment "  7. Call handler with request and continuation"
      -- The handler is a closure that expects the request value.
      -- For MVP, the handler should use MatchRequest to dispatch.
      -- We call the handler via call_indirect with the request as argument.

      -- Load handler's function index from PAp header
      , LocalGet "__handler_ptr"
      , I32Load (fromIntegral ABI.pApFuncRefOffset)  -- Get func table index from PAp
      , LocalSet "__handler_func_idx"

      -- Push the request as argument (i64)
      , LocalGet "__req_ptr"
      , I64ExtendI32U

      -- Push the captured continuation as second argument (i64)
      -- Handlers need access to the continuation to resume
      , LocalGet "__captured_ptr"
      , I64ExtendI32U

      -- Call handler via call_indirect (arity 2: request, continuation)
      -- Stack has: [request, continuation], then we push index
      , LocalGet "__handler_func_idx"
      , CallIndirect "arity2"
      ]

-- Pattern match on integral values (MatchIntegral)
compileANormal ctx (TMatch v (MatchIntegral cases defaultCase)) = do
  compileIntegralMatch ctx v (EC.mapToList cases) defaultCase

-- Pattern match on boxed numeric values (MatchNumeric)
-- Same as MatchIntegral but for boxed data (produced by parser)
compileANormal ctx (TMatch v (MatchNumeric _ref cases defaultCase)) = do
  compileIntegralMatch ctx v (EC.mapToList cases) defaultCase

-- Pattern match on data types (MatchData) - sum type dispatch
-- For enums (no fields), dispatch on the tag value
-- For data with fields, extract fields and bind to local variables
compileANormal ctx (TMatch v (MatchData _ref cases defaultCase)) = do
  -- Separate enum cases (no fields) from data cases (with fields)
  let allCases = EC.mapToList cases
      enumCases = [(rawTag tag, body) | (tag, ([], body)) <- allCases]
      dataCases = [(rawTag tag, mems, body) | (tag, (mems, body)) <- allCases, not (null mems)]

  if null dataCases
    then -- All enum cases: use simple if-else chain
      compileIfElseChain ctx v enumCases defaultCase
    else -- Mixed cases with field bindings
      compileDataMatch ctx v allCases defaultCase

-- Pattern match on ability requests (MatchRequest)
-- Used in handler bodies to match on the operation being performed.
-- Structure: TMatch v (MatchRequest abilityBranches pureCase)
-- where abilityBranches is [(ref, EnumMap CTag ([Mem], e))]
--
-- The scrutinee is a "request" value with a packed tag encoding:
-- - If tag == pureEffectTag: it's a pure value (handled by pureCase)
-- - Otherwise: unpack (effect_ref, ctor_tag) and dispatch to handler branch
compileANormal ctx (TMatch v (MatchRequest abilityBranches pureCase)) = do
  case lookupVar v ctx of
    Nothing -> Left $ UnboundVariable $ Var.name v
    Just (localIdx, _) -> do
      let scrutLocal = "p" ++ show localIdx

      -- Compile the pure case (when effect is "pure" / already handled)
      pureCaseInstrs <- compileANormal ctx pureCase

      -- For MVP: generate if-else chain for ability branches
      -- Full implementation would extract packed tag from the request object
      branchInstrs <- compileRequestBranches ctx scrutLocal abilityBranches

      pure $
        [ Comment "MatchRequest: Match on ability request"
        , Comment $ "  Scrutinee: " ++ scrutLocal

        -- In native runtime, the scrutinee is a data value with a packed tag.
        -- We load the tag and check if it's pure (tag == 0 for pure effect).
        -- For MVP, we assume the scrutinee is a boxed value and load its tag.

        -- Load the scrutinee pointer
        , LocalGet scrutLocal
        , I32WrapI64  -- Convert i64 to pointer

        -- Load the ctor_id from the data object (at offset 12 for enum/data objects)
        -- This gives us the packed effect tag
        , I32Load (fromIntegral ABI.enumCtorIdOffset)
        , LocalSet "__frame_tag"  -- Reuse as request_tag

        -- Check if pure (tag == 0, representing pureEffectTag)
        , LocalGet "__frame_tag"
        , I32Eqz
        , If I64
            pureCaseInstrs
            branchInstrs
        ]

-- TName: bind a closure to a variable
-- TName v f as body: create PAp for function f with captured args as, bind to v, execute body
compileANormal ctx (TName v f args bo) = do
  -- Get function table index and arity
  (tableIdx, arity) <- case f of
    Left ref ->
      case (Map.lookup ref (ctxRefTableIndices ctx), Map.lookup ref (ctxRefArities ctx)) of
        (Just idx, Just a) -> pure (idx, a)
        (Nothing, _) -> Left $ UnsupportedConstruct $ "No table index for reference in TName"
        (_, Nothing) -> Left $ UnsupportedConstruct $ "Unknown arity for reference in TName"
    Right funcVar ->
      -- For local function variables, we don't have table indices yet
      -- This would require extending ctxFuncTableIndices
      case Map.lookup funcVar (ctxFuncArities ctx) of
        Just a -> pure (varToFuncId funcVar, a)  -- Fallback to hash for now
        Nothing -> Left $ UnsupportedConstruct $ "TName with unknown function variable"

  let capturedCount = length args
      -- Create the local variable for the PAp pointer
      localName = "p" ++ show (ctxNextLocal ctx)
      newCtx = ctx
        { ctxVars = Map.insert v (ctxNextLocal ctx, BX) (ctxVars ctx),
          ctxNextLocal = ctxNextLocal ctx + 1,
          ctxLocals = ctxLocals ctx ++ [(localName, I32)]  -- PAp pointer is i32
        }

  -- Compile the body with the new binding
  bodyInstrs <- compileANormal newCtx bo

  -- Generate PAp allocation
  let allocInstrs =
        [ -- Allocate PAp: __alloc_pap(table_idx, arity, captured_count)
          I32Const (fromIntegral tableIdx),
          I32Const (fromIntegral arity),
          I32Const (fromIntegral capturedCount),
          Call "__alloc_pap",
          LocalSet localName
        ]

  -- Store captured arguments into the PAp (reads from existing locals)
  storeInstrs <- storePApArgs ctx localName 0 args

  pure $ allocInstrs ++ storeInstrs ++ bodyInstrs

--------------------------------------------------------------------------------
-- Ability Handler Constructs (Phase 5)
--------------------------------------------------------------------------------

-- THnd: Install an ability handler (push Mark frame)
-- THnd refs handlerVar affineHandler body
-- refs: list of ability references being handled
-- handlerVar: variable holding the handler closure
-- affineHandler: optional affine handler (for optimization)
-- body: code to run under the handler
--
-- Implementation mirrors native runtime's Reset instruction:
-- 1. Save current denv (will be stored in Mark frame)
-- 2. Insert handler into denv for this ability
-- 3. Push Mark frame onto K stack
-- 4. Run body
-- 5. Pop Mark frame, restore denv from Mark frame
compileANormal ctx (THnd refs handlerVar _affineHandler body) = do
  -- Get the handler variable location
  let handlerInfo = lookupVar handlerVar ctx

  case handlerInfo of
    Nothing -> Left $ UnboundVariable $ Var.name handlerVar
    Just (handlerIdx, _) -> do
      let handlerLocal = "p" ++ show handlerIdx

      -- Convert all ability refs to i32
      let abilityRefs = map refToI32 refs
          -- Primary ref for Mark frame (used for TShift matching)
          primaryRef = case abilityRefs of
            (r : _) -> r
            [] -> 0

      -- Compile the body
      bodyInstrs <- compileANormal ctx body

      -- Generate instructions to insert handler into denv for each ability
      let insertHandlerInstrs ref =
            [ GlobalGet "denv_ptr"  -- Current denv
            , I32Const ref           -- Ability key
            , LocalGet handlerLocal
            , I32WrapI64             -- Handler pointer
            , Call "__denv_insert"
            , GlobalSet "denv_ptr"   -- Update denv with new handler
            ]

      -- Insert handler for all abilities (multi-ability support)
      let allInsertInstrs = concatMap insertHandlerInstrs abilityRefs

      -- Generate: install handler, push Mark frame, run body, pop Mark frame, restore denv
      pure $
        [ Comment "THnd: Install ability handler"
        , Comment $ "  Ability refs: " ++ show abilityRefs

        -- 1. Push Mark frame first (saves current k_ptr and denv_ptr)
        --    Uses primary ref for TShift matching
        , I32Const 0  -- pending_args (0 at installation time)
        , I32Const primaryRef
        , LocalGet handlerLocal
        , I32WrapI64  -- Handler is i64, convert to i32 pointer
        , Call "__alloc_mark"
        , GlobalSet "k_ptr"  -- Push Mark frame to K stack
        ]
          -- 2. Insert handler into denv for each ability ref
          ++ allInsertInstrs
          ++ bodyInstrs
          ++ [ Comment "THnd: Pop Mark frame (handler completed normally)"
             -- Restore denv from Mark frame's saved denv
             , GlobalGet "k_ptr"
             , I32Load (fromIntegral ABI.kMarkLocalCountOffset)  -- Saved denv is at this offset
             , GlobalSet "denv_ptr"
             -- Pop Mark frame
             , GlobalGet "k_ptr"
             , I32Load (fromIntegral ABI.kMarkNextKOffset)
             , GlobalSet "k_ptr"
             ]

-- TShift: Capture continuation up to a prompt
-- TShift ref contVar body
-- ref: ability reference to capture up to
-- contVar: variable to bind the captured continuation to
-- body: code to run with the captured continuation
--
-- Implementation mirrors native runtime's Capture instruction + splitCont:
-- 1. Walk K stack to find Mark frame matching this ability ref
-- 2. Create Captured object containing the K chain from current to Mark
-- 3. Restore denv from Mark frame
-- 4. Pop frames up to and including the Mark
-- 5. Bind Captured to contVar and run body
compileANormal ctx (TShift ref contVar body) = do
  -- Create context with continuation binding
  let contLocal = "p" ++ show (ctxNextLocal ctx)
      newCtx = ctx
        { ctxVars = Map.insert contVar (ctxNextLocal ctx, BX) (ctxVars ctx),
          ctxNextLocal = ctxNextLocal ctx + 1,
          ctxLocals = ctxLocals ctx ++ [(contLocal, I64)] -- Continuation is boxed pointer
        }

  -- Ability reference to search for
  let abilityRef = refToI32 ref

  -- Compile the body with the continuation bound
  bodyInstrs <- compileANormal newCtx body

  -- Generate continuation capture code
  -- We need helper locals for the walk:
  -- __k_walk: current frame being examined
  -- __k_start: where we started (to store in Captured)
  -- __mark_ptr: the Mark frame when found
  pure $
    [ Comment $ "TShift: Capture continuation for ability " ++ show abilityRef
    , Comment "  Walk K to find matching Mark frame"

    -- Save starting k_ptr (this will be stored in Captured)
    , GlobalGet "k_ptr"
    , LocalSet "__k_start"

    -- Walk K to find the Mark frame for this ability
    , GlobalGet "k_ptr"
    , LocalSet "__k_walk"

    -- Loop to find the matching Mark frame
    , Block "shift_found"
        [ Loop "shift_walk"
            [ -- Check if we've hit KE (k_walk == 0)
              LocalGet "__k_walk"
            , I32Eqz
            , IfVoid
                [ Comment "Error: fell off K stack without finding Mark"
                , Unreachable
                ]
                []

            -- Load frame tag
            , LocalGet "__k_walk"
            , I32Load8U (fromIntegral ABI.kPushFrameTagOffset)
            , LocalSet "__frame_tag"

            -- Check if it's a Mark frame (tag == FRAME_MARK)
            , LocalGet "__frame_tag"
            , I32Const (fromIntegral $ ABI.frameTagToWord8 ABI.frameMark)
            , I32Eq
            , IfVoid
                [ -- It's a Mark frame - check if ability matches
                  LocalGet "__k_walk"
                , I32Load (fromIntegral ABI.kMarkAbilityRefOffset)
                , I32Const abilityRef
                , I32Eq
                , IfVoid
                    [ -- Found matching Mark! Save it and exit loop
                      LocalGet "__k_walk"
                    , LocalSet "__mark_ptr"
                    , Br "shift_found"
                    ]
                    [ -- Not our ability, continue walking
                      LocalGet "__k_walk"
                    , I32Load (fromIntegral ABI.kMarkNextKOffset)
                    , LocalSet "__k_walk"
                    , Br "shift_walk"
                    ]
                ]
                [ -- Not a Mark frame (must be Push), continue walking
                  LocalGet "__k_walk"
                , I32Load (fromIntegral ABI.kPushNextKOffset)
                , LocalSet "__k_walk"
                , Br "shift_walk"
                ]
            ]
        ]

    , Comment "  Found Mark frame, create Captured object"
    -- Allocate Captured: stores k_ptr, pending_args, slot_count
    -- Count of locals to save: all locals bound before this shift point
    , LocalGet "__k_start"   -- The K chain to capture
    , I32Const 0             -- pending_args
    , I32Const (fromIntegral $ ctxNextLocal ctx)  -- Number of locals to save
    , Call "__alloc_captured"
    , LocalSet "__captured_ptr"  -- Store, don't tee (avoid stack value)
    ]
      -- Save all locals to Captured slots
      ++ concatMap (saveLocalToCapture $ ctxNextLocal ctx) [0 .. ctxNextLocal ctx - 1]
      ++
    [ LocalGet "__captured_ptr"
    , I64ExtendI32U          -- Convert to i64 for boxed representation
    , LocalSet contLocal     -- Bind continuation to variable

    , Comment "  Restore denv from Mark frame"
    , LocalGet "__mark_ptr"
    , I32Load (fromIntegral ABI.kMarkLocalCountOffset)  -- Saved denv
    , GlobalSet "denv_ptr"

    , Comment "  Pop K stack up to and including Mark frame"
    , LocalGet "__mark_ptr"
    , I32Load (fromIntegral ABI.kMarkNextKOffset)
    , GlobalSet "k_ptr"
    ]
      ++ bodyInstrs

-- TKon: Resume a captured continuation (TApp FCont args)
-- contVar: variable holding the captured continuation
-- args: arguments to pass to the continuation
--
-- Implementation mirrors native runtime's Jump instruction:
-- 1. Load the Captured object
-- 2. Get the saved K chain from it
-- 3. Splice the captured K chain onto current K
-- 4. Return the argument value (which becomes the result of the shift)
--
-- For MVP, we simplify by just restoring k_ptr and returning the arg.
-- A full implementation would walk the captured K and truly splice it,
-- restoring any saved locals from Push frames.
compileANormal ctx (TKon contVar args) = do
  -- Get the continuation variable location
  let contInfo = lookupVar contVar ctx

  case contInfo of
    Nothing -> Left $ UnboundVariable $ Var.name contVar
    Just (contIdx, _) -> do
      let contLocal = "p" ++ show contIdx

      -- Compile arguments to pass to continuation (these become the shift result)
      -- In the native runtime, these are passed to closeArgs then dumpSeg.
      -- For MVP, we just return the first argument.
      argInstrs <- concat <$> mapM (compileANormal ctx . TVar) args

      pure $
        [ Comment "TKon: Resume captured continuation"
        , Comment $ "  Continuation var: " ++ contLocal

        -- Get the Captured object pointer
        , LocalGet contLocal
        , I32WrapI64  -- Convert i64 to i32 pointer
        , LocalSet "__cont_ptr"

        -- The captured K chain needs to be spliced onto current K.
        -- The chain was captured from __k_start to __mark_ptr (exclusive).
        -- We need to find the tail of the captured chain (frame whose next == mark_next)
        -- and patch it to point to current k_ptr.
        --
        -- For MVP simplification: we assume the captured chain is shallow
        -- and just restore it directly. This works for simple handlers
        -- that don't nest calls within the handled scope.

        , Comment "  Load captured K chain start"
        , LocalGet "__cont_ptr"
        , I32Load (fromIntegral ABI.capturedKPtrOffset)
        , LocalSet "__k_walk"

        -- Walk to find the end of the captured chain (where next_k == 0 or is the old k_ptr)
        -- For MVP: just prepend the whole captured chain
        -- More complex: walk to end and patch

        , Comment "  Find end of captured K chain and patch to current k_ptr"
        , Block "repush_done"
            [ Loop "repush_walk"
                [ -- If __k_walk is 0 (KE), we're done
                  LocalGet "__k_walk"
                , I32Eqz
                , BrIf "repush_done"

                -- Load frame tag
                , LocalGet "__k_walk"
                , I32Load8U 0
                , LocalSet "__frame_tag"

                -- Get next_k offset based on frame type
                -- (Both Push and Mark have next_k at same offset: 4)
                , LocalGet "__k_walk"
                , I32Load (fromIntegral ABI.kPushNextKOffset)  -- next_k is at offset 4 for both
                , LocalTee "__k_start"  -- Reuse __k_start as next_ptr temp

                -- If next_k is 0, we've found the end - patch it
                , I32Eqz
                , IfVoid
                    [ -- Patch this frame's next_k to point to current k_ptr
                      LocalGet "__k_walk"
                    , GlobalGet "k_ptr"
                    , I32Store (fromIntegral ABI.kPushNextKOffset)
                    , Br "repush_done"
                    ]
                    [ -- Not at end, continue walking
                      LocalGet "__k_start"  -- next_ptr is in __k_start
                    , LocalSet "__k_walk"
                    , Br "repush_walk"
                    ]
                ]
            ]

        , Comment "  Set k_ptr to start of captured chain"
        , LocalGet "__cont_ptr"
        , I32Load (fromIntegral ABI.capturedKPtrOffset)
        , GlobalSet "k_ptr"

        , Comment "  Restore locals from Captured object"
        -- Read slot_count from Captured
        , LocalGet "__cont_ptr"
        , I32Load (fromIntegral ABI.capturedCountOffset)
        , LocalSet "__frame_tag"  -- Reuse as slot_count temp
        ]
          -- Generate restore code for each possible local
          -- We check if slot_count > localIdx before restoring each
          ++ concatMap (restoreLocalConditionally) [0 .. ctxNextLocal ctx - 1]
          ++ argInstrs
          ++
          -- Return the argument (which becomes the result of the shift expression)
          [ Comment "  Return argument as shift result"
          , if null argInstrs then I64Const 0 else Nop
          ]
  where
    -- | Generate conditional restore for a single local
    -- Only restores if slot_count > localIdx (i.e., localIdx < slot_count)
    restoreLocalConditionally :: Int -> [WatInstr]
    restoreLocalConditionally localIdx =
      [ I32Const (fromIntegral localIdx)
      , LocalGet "__frame_tag"  -- slot_count
      , I32LtU  -- localIdx < slot_count
      , IfVoid
          [ LocalGet "__cont_ptr"
          , I64Load (fromIntegral ABI.capturedSlotsOffset + fromIntegral localIdx * 8)
          , LocalSet ("p" ++ show localIdx)
          ]
          []
      ]

-- Foreign function call: calls an imported JS function
compileANormal ctx (TFOp foreignFunc args) = do
  -- Compile arguments (push onto stack as i64)
  argInstrs <- concat <$> mapM (compileANormal ctx . TVar) args
  -- Call the imported function using its sanitized name
  let funcName = foreignFuncToImportName foreignFunc
  pure $ argInstrs ++ [Call funcName]

-- Fallback for unsupported constructs
compileANormal _ctx _term = do
  Left $ UnsupportedConstruct "Unsupported ANormal construct"

--------------------------------------------------------------------------------
-- PAp Helper Functions
--------------------------------------------------------------------------------

-- | Store captured arguments into a PAp object.
--
-- Each argument is stored as a TypedSlot (16 bytes): TypeTag + Payload64.
storePApArgs ::
  (Var v) =>
  CompileCtx v ->
  String ->           -- PAp pointer local name
  Int ->              -- Current argument index
  [v] ->              -- Remaining arguments to store
  CompileResult [WatInstr]
storePApArgs _ _ _ [] = pure []
storePApArgs ctx ptrName idx (arg : rest) = do
  case lookupVar arg ctx of
    Nothing -> Left $ UnboundVariable $ Var.name arg
    Just (localIdx, mem) -> do
      let offset = fromIntegral ABI.pApArgsOffset + fromIntegral idx * fromIntegral ABI.typedSlotSize
          argLocalName = "p" ++ show localIdx
          typeTag = memToTypeTag mem

      -- Store TypeTag at offset
      let storeTag =
            [ LocalGet ptrName,
              I32Const (fromIntegral typeTag),
              I32Store offset
            ]

      -- Store value at offset + 8
      let storeVal =
            [ LocalGet ptrName,
              LocalGet argLocalName,
              I64Store (offset + 8)
            ]

      restInstrs <- storePApArgs ctx ptrName (idx + 1) rest
      pure $ storeTag ++ storeVal ++ restInstrs

-- | Convert memory classification to TypeTag
memToTypeTag :: Mem -> Word32
memToTypeTag UN = fromIntegral $ ABI.typeTagToWord8 ABI.typeNat
memToTypeTag BX = fromIntegral $ ABI.typeTagToWord8 ABI.typeBoxed

-- | Helper to get a numeric function ID from a variable
-- Used as fallback when table index isn't available
varToFuncId :: (Var v) => v -> Int
varToFuncId v = fromIntegral $ Text.length (Var.name v)

-- | Get the TypeTag for a variable as an i32 constant
getVarTypeTag :: (Var v) => CompileCtx v -> v -> Word32
getVarTypeTag ctx v =
  case lookupVar v ctx of
    Just (_, mem) -> memToTypeTag mem
    Nothing -> fromIntegral $ ABI.typeTagToWord8 ABI.typeBoxed -- Default to boxed

-- | Convert a Reference to an i32 for type_ref storage
-- Uses hash of builtin name or first 4 bytes of derived hash (MVP simplification)
refToI32 :: Reference -> Word32
refToI32 (Reference.Builtin t) = fromIntegral $ Text.length t `mod` 0x10000
refToI32 (Reference.DerivedId (Reference.Id h _)) =
  -- Extract first 4 bytes of hash as u32
  let bs = Hash.toByteString h
      bytes = take 4 (BS.unpack bs ++ [0, 0, 0, 0])
   in foldr (\b acc -> acc * 256 + fromIntegral b) 0 bytes

-- | Store fields into a DataG object
storeDataGFields ::
  (Var v) =>
  CompileCtx v ->
  [v] ->         -- Fields to store
  Int ->         -- Current field index
  CompileResult [WatInstr]
storeDataGFields _ [] _ = pure []
storeDataGFields ctx (field : rest) idx = do
  case lookupVar field ctx of
    Nothing -> Left $ UnboundVariable $ Var.name field
    Just (localIdx, mem) -> do
      let fieldOffset = fromIntegral ABI.dataGFieldsOffset + fromIntegral idx * fromIntegral ABI.typedSlotSize
          localName = "p" ++ show localIdx
          typeTag = memToTypeTag mem
      -- Store TypeTag at offset
      let storeTag =
            [ LocalGet "__datag_temp",
              I32Const typeTag,
              I32Store fieldOffset
            ]
      -- Store value at offset + 8
      let storeVal =
            [ LocalGet "__datag_temp",
              LocalGet localName,
              I64Store (fieldOffset + 8)
            ]
      restInstrs <- storeDataGFields ctx rest (idx + 1)
      pure $ storeTag ++ storeVal ++ restInstrs

--------------------------------------------------------------------------------
-- Pattern Matching
--------------------------------------------------------------------------------

-- | Compile MatchIntegral/MatchNumeric with full multi-case support
--
-- Supports an arbitrary number of cases using an if-else chain.
-- Each case compares the scrutinee against a value and branches
-- to the appropriate body.
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
  CompileCtx v ->
  v ->                                        -- Scrutinee variable
  [(CTag, ([Mem], ANormal Reference v))] ->   -- Cases with field info
  Maybe (ANormal Reference v) ->              -- Default case
  CompileResult [WatInstr]
compileDataMatch ctx scrutVar cases mDefault = do
  compileDataMatchChain ctx scrutVar cases mDefault

-- | Build an if-else chain for data matching
compileDataMatchChain ::
  (Var v) =>
  CompileCtx v ->
  v ->
  [(CTag, ([Mem], ANormal Reference v))] ->
  Maybe (ANormal Reference v) ->
  CompileResult [WatInstr]

-- Base case: no more cases
compileDataMatchChain ctx _ [] (Just dflt) = compileANormal ctx dflt
compileDataMatchChain _ _ [] Nothing = pure [Unreachable]

-- Recursive case: check one case
compileDataMatchChain ctx scrutVar ((tag, (mems, body)):rest) mDefault = do
  -- Load scrutinee tag (i64) for comparison
  scrutInstrs <- compileANormal ctx (TVar scrutVar)
  let tagVal = rawTag tag

  -- Compile body with field bindings
  bodyInstrs <- if null mems
    then compileANormal ctx body
    else compileWithFieldBindings ctx scrutVar mems body

  -- Compile else branch
  elseInstrs <- compileDataMatchChain ctx scrutVar rest mDefault

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
  CompileCtx v ->
  v ->                     -- Scrutinee variable (holds pointer to data object)
  [Mem] ->                 -- Field memory classifications (extracted from ANormal)
  ANormal Reference v ->   -- Body (with ABTN.TAbs wrapping field bindings)
  CompileResult [WatInstr]
compileWithFieldBindings ctx scrutVar mems body = do
  -- The body should be wrapped in TAbs nodes that introduce field variables
  -- We need to unwrap it and extract the field variable names
  let (fieldVars, innerBody) = extractAbsVars body

  -- If the number of field variables doesn't match mems, something is wrong
  if length fieldVars /= length mems
    then Left $ UnsupportedConstruct $
           "Field count mismatch: expected " <> Text.pack (show (length mems))
           <> " but got " <> Text.pack (show (length fieldVars))
    else do
      -- Create context with field bindings
      let fieldBindings = zip fieldVars mems
          newCtx = bindVars fieldBindings ctx

      -- Get the scrutinee as a pointer
      let (scrutIdx, _) = case lookupVar scrutVar ctx of
            Just x -> x
            Nothing -> (-1, UN)  -- Will error below
          scrutLocal = "p" ++ show scrutIdx

      -- Generate field extraction code
      extractInstrs <- extractDataFields scrutLocal mems newCtx fieldVars

      -- Compile the inner body with new context
      bodyInstrs <- compileANormal newCtx innerBody

      pure $ extractInstrs ++ bodyInstrs

-- | Extract bound variables from nested TAbs wrappers
extractAbsVars :: (Var v) => ANormal Reference v -> ([v], ANormal Reference v)
extractAbsVars (ABTN.TAbs v rest) =
  let (moreVars, inner) = extractAbsVars rest
   in (v : moreVars, inner)
extractAbsVars other = ([], other)

-- | Compile ability request branches for MatchRequest
-- Each branch is (ability_ref, cases_map) where cases_map maps operation tags to handlers
compileRequestBranches ::
  (Var v) =>
  CompileCtx v ->
  String ->                                            -- Scrutinee local name
  [(Reference, EC.EnumMap CTag ([Mem], ANormal Reference v))] ->  -- Ability branches
  CompileResult [WatInstr]
compileRequestBranches _ctx _scrutLocal [] =
  -- No branches, unhandled ability request
  pure [Unreachable]
compileRequestBranches ctx scrutLocal ((ref, casesMap) : rest) = do
  -- Generate code for this ability's operations
  let abilityRef = refToI32 ref
      cases = EC.mapToList casesMap

  -- For MVP: generate if-else chain for operations within this ability
  -- In a full implementation, we'd first check the ability ref, then dispatch on operation
  opCaseInstrs <- compileOperationCases ctx scrutLocal cases

  -- Compile remaining abilities
  restInstrs <- compileRequestBranches ctx scrutLocal rest

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
  CompileCtx v ->
  String ->                                        -- Scrutinee local name
  [(CTag, ([Mem], ANormal Reference v))] ->        -- (operation tag, (args mems, body))
  CompileResult [WatInstr]
compileOperationCases _ctx _scrutLocal [] = pure [Unreachable]
compileOperationCases ctx scrutLocal [(_tag, (mems, body))] = do
  -- Single case: just compile the body with field bindings
  if null mems
    then compileANormal ctx body
    else do
      -- The body has TAbs wrappers for the operation arguments
      let (fieldVars, innerBody) = extractAbsVars body
      if length fieldVars /= length mems
        then compileANormal ctx body  -- Fallback if mismatch
        else do
          let fieldBindings = zip fieldVars mems
              newCtx = bindVars fieldBindings ctx
          -- Generate field extraction code (from request object)
          extractInstrs <- extractDataFields scrutLocal mems newCtx fieldVars
          bodyInstrs <- compileANormal newCtx innerBody
          pure $ extractInstrs ++ bodyInstrs

compileOperationCases ctx scrutLocal ((tag, (mems, body)) : rest) = do
  let tagVal = rawTag tag

  -- Compile this operation's body
  thenInstrs <- compileOperationCases ctx scrutLocal [(tag, (mems, body))]

  -- Compile remaining operations
  elseInstrs <- compileOperationCases ctx scrutLocal rest

  pure
    [ Comment $ "  Operation tag: " ++ show tagVal
    -- Load operation tag from request object
    , LocalGet scrutLocal
    , I32WrapI64
    , I32Load (fromIntegral ABI.enumCtorIdOffset)
    , I32Const (fromIntegral tagVal)
    , I32Eq
    , If I64 thenInstrs elseInstrs
    ]

-- | Generate instructions to extract fields from a data object.
--
-- Uses ABI offsets to load fields as TypedSlots.
extractDataFields ::
  (Var v) =>
  String ->        -- Scrutinee local name (holds pointer)
  [Mem] ->         -- Field memory classifications
  CompileCtx v ->  -- New context with field bindings
  [v] ->           -- Field variable names
  CompileResult [WatInstr]
extractDataFields _ [] _ [] = pure []
extractDataFields scrutLocal (mem : restMems) ctx (fieldVar : restVars) = do
  let numFields = length restMems + 1
      fieldIdx = numFields - 1 - length restMems  -- 0-indexed field position

  -- Determine offset based on number of fields (Data1, Data2, DataG)
  let fieldOffset = case numFields of
        1 -> fromIntegral ABI.data1Field0Offset + 8  -- Skip TypeTag
        2 | fieldIdx == 0 -> fromIntegral ABI.data2Field0Offset + 8
          | otherwise -> fromIntegral ABI.data2Field1Offset + 8
        _ -> fromIntegral ABI.dataGFieldsOffset +
             fromIntegral fieldIdx * fromIntegral ABI.typedSlotSize + 8

  -- Get the local name for this field
  let (localIdx, _) = case lookupVar fieldVar ctx of
        Just x -> x
        Nothing -> (-1, UN)
      localName = "p" ++ show localIdx

  -- Generate extraction instruction
  -- The scrutinee is an i64 (boxed pointer), so we need to wrap it to i32
  let extractInstr =
        [ LocalGet scrutLocal
        , I32WrapI64          -- Convert i64 to i32 pointer
        , case mem of
            UN -> I64Load fieldOffset  -- Unboxed: load payload directly
            BX -> I64Load fieldOffset  -- Boxed: load payload (another pointer)
        , LocalSet localName
        ]

  restInstrs <- extractDataFields scrutLocal restMems ctx restVars
  pure $ extractInstr ++ restInstrs

extractDataFields _ _ _ _ = pure [] -- Mismatched lengths, shouldn't happen

--------------------------------------------------------------------------------
-- PAp Invocation (Dynamic Dispatch)
--------------------------------------------------------------------------------

-- | Generate code to apply arguments to a PAp (closure).
--
-- Strategy:
-- 1. Check if capturedCount + numNewArgs < expectedArity (partial application)
-- 2. If partial: create new PAp with additional captured args
-- 3. If saturated: dispatch via call_indirect based on capturedCount
--
-- Note: The papLocal contains an i64 (boxed pointer), but memory operations
-- need i32. We wrap it with i32.wrap_i64.
--
-- All offsets use ABI constants from 'Unison.Wasm.ABI'.
compileApplyPAp :: String -> Int -> [WatInstr] -> [WatInstr]
compileApplyPAp papLocal numNewArgs argInstrs =
  let
    -- ABI constants (avoid magic numbers)
    funcRefOffset :: Word32
    funcRefOffset = fromIntegral ABI.pApFuncRefOffset

    arityOffset :: Word32
    arityOffset = fromIntegral ABI.pApExpectedArityOffset

    capturedCountOffset :: Word32
    capturedCountOffset = fromIntegral ABI.pApCapturedCountOffset

    argsBaseOffset :: Word32
    argsBaseOffset = fromIntegral ABI.pApArgsOffset

    -- Get PAp pointer as i32 from the i64 boxed value
    getPapPtr :: [WatInstr]
    getPapPtr = [LocalGet papLocal] ++ P.wrapI64ToPtr

    -- Read PAp fields using ABI offsets
    readFuncId :: [WatInstr]
    readFuncId = getPapPtr ++ [I32Load funcRefOffset]

    readExpectedArity :: [WatInstr]
    readExpectedArity = getPapPtr ++ [I32Load16U arityOffset]

    readCapturedCount :: [WatInstr]
    readCapturedCount = getPapPtr ++ [I32Load16U capturedCountOffset]

    -- Load captured arg payload at index i
    -- Offset = argsBaseOffset + i * slotSize + 8 (skip TypeTag)
    loadCapturedArg :: Int -> [WatInstr]
    loadCapturedArg i =
      getPapPtr ++ [I64Load (P.slotPayloadOffset argsBaseOffset (fromIntegral i))]

    -- Generate code for a specific capturedCount when fully saturated
    genSaturatedCase :: Int -> [WatInstr]
    genSaturatedCase cc =
      let totalArity = cc + numNewArgs
       in concatMap loadCapturedArg [0 .. cc - 1]
            ++ argInstrs
            ++ readFuncId
            ++ [CallIndirect (Runtime.arityTypeName totalArity)]

    -- Check: capturedCount + numNewArgs < expectedArity?
    checkPartial :: [WatInstr]
    checkPartial =
      readCapturedCount
        ++ [I32Const (fromIntegral numNewArgs), I32Add]
        ++ readExpectedArity
        ++ [I32LtU]

    -- Generate code for partial application (return new PAp)
    genPartialCase :: [WatInstr]
    genPartialCase =
      -- Allocate new PAp: __alloc_pap(func_id, expected_arity, new_captured_count)
      readFuncId
        ++ readExpectedArity
        ++ readCapturedCount
        ++ [I32Const (fromIntegral numNewArgs), I32Add]
        ++ [Call "__alloc_pap", LocalSet "__pap_temp"]
        ++ genCopyOldArgs
        ++ genStoreNewArgs
        ++ [LocalGet "__pap_temp"]
        ++ P.extendPtrToI64

    -- Copy old captured args using dispatch on count
    genCopyOldArgs :: [WatInstr]
    genCopyOldArgs = buildCopyDispatch 0

    buildCopyDispatch :: Int -> [WatInstr]
    buildCopyDispatch n
      | n >= Runtime.maxSupportedArity = []
      | n == 0 =
          -- Special case: if capturedCount == 0, nothing to copy
          readCapturedCount
            ++ [I32Const 0, I32Eq, IfVoid [] (buildCopyDispatch 1)]
      | otherwise =
          readCapturedCount
            ++ [ I32Const (fromIntegral n),
                 I32Eq,
                 IfVoid
                   (concatMap copyOneArg [0 .. n - 1])
                   (buildCopyDispatch (n + 1))
               ]

    -- Copy one arg at index i from old PAp to new PAp
    -- Uses inline pointer generation (no extra local needed)
    copyOneArg :: Int -> [WatInstr]
    copyOneArg i =
      let offset = P.slotPayloadOffset argsBaseOffset (fromIntegral i)
       in [ LocalGet "__pap_temp" -- dest: new PAp
          ]
            ++ getPapPtr -- src: old PAp pointer
            ++ [ I64Load offset, -- load from old PAp
                 I64Store offset -- store to new PAp at same position
               ]

    -- Store new arguments at position = old capturedCount
    genStoreNewArgs :: [WatInstr]
    genStoreNewArgs
      | numNewArgs == 1 = buildStoreDispatch 0
      | otherwise = [] -- TODO: handle multiple new args

    buildStoreDispatch :: Int -> [WatInstr]
    buildStoreDispatch n
      | n >= Runtime.maxSupportedArity = []
      | otherwise =
          let offset = P.slotPayloadOffset argsBaseOffset (fromIntegral n)
           in readCapturedCount
                ++ [ I32Const (fromIntegral n),
                     I32Eq,
                     IfVoid
                       ([LocalGet "__pap_temp"] ++ argInstrs ++ [I64Store offset])
                       (buildStoreDispatch (n + 1))
                   ]

    -- Build saturated dispatch using recursive helper
    buildSaturatedSwitch :: [WatInstr]
    buildSaturatedSwitch = buildSaturatedDispatch 0

    buildSaturatedDispatch :: Int -> [WatInstr]
    buildSaturatedDispatch cc
      | cc + numNewArgs > Runtime.maxSupportedArity = [Unreachable]
      | cc + numNewArgs == Runtime.maxSupportedArity = genSaturatedCase cc
      | otherwise =
          readCapturedCount
            ++ [ I32Const (fromIntegral cc),
                 I32Eq,
                 If I64 (genSaturatedCase cc) (buildSaturatedDispatch (cc + 1))
               ]

    -- Full dispatch: check if partial, then branch
    fullDispatch :: [WatInstr]
    fullDispatch =
      checkPartial
        ++ [If I64 genPartialCase buildSaturatedSwitch]
   in fullDispatch

--------------------------------------------------------------------------------
-- Literal Compilation
--------------------------------------------------------------------------------

-- | Compile a literal to WASM instructions
-- Note: All values are stored as i64, so floats are reinterpreted to i64.
compileLit :: Lit Reference -> CompileResult [WatInstr]
compileLit (N n) = pure [I64Const n]
compileLit (I n) = pure [I64Const (fromIntegral n)]
compileLit (F f) = pure [F64Const f, I64ReinterpretF64]  -- Store as i64
compileLit (C c) = pure [I64Const (fromIntegral (fromEnum c))]  -- Unicode codepoint as i64
compileLit (T _t) = Left $ UnsupportedConstruct "Text literals not yet supported"
compileLit (LM _) = Left $ UnsupportedConstruct "Term links not yet supported"
compileLit (LY _) = Left $ UnsupportedConstruct "Type links not yet supported"

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
compilePrimOp INCN 1 = pure I64Add -- Caller pushes 1; we just emit add
compilePrimOp DECN 1 = pure I64Sub -- Caller pushes 1; we just emit sub
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
compilePrimOp NEGI 1 = pure I64Sub -- Caller pushes 0; we emit sub for (0 - x)
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
--
-- Note: Comparison ops return i32 in WASM, so we extend to i64.
-- Float ops produce f64, so we reinterpret to i64 for the return value.
builtinToPrimOp :: Text -> Int -> Maybe [WatInstr]
-- Nat operations (the ## prefix is stripped by the parser)
builtinToPrimOp "Nat.+" 2 = Just [I64Add]
builtinToPrimOp "Nat.sub" 2 = Just [I64Sub]
builtinToPrimOp "Nat.*" 2 = Just [I64Mul]
builtinToPrimOp "Nat./" 2 = Just [I64DivU]
builtinToPrimOp "Nat.mod" 2 = Just [I64RemU]
builtinToPrimOp "Nat.<=" 2 = Just [I64LeU, I64ExtendI32U]  -- Comparison returns i32, extend to i64
builtinToPrimOp "Nat.<" 2 = Just [I64LtU, I64ExtendI32U]
builtinToPrimOp "Nat.==" 2 = Just [I64Eq, I64ExtendI32U]
builtinToPrimOp "Universal.==" 2 = Just [I64Eq, I64ExtendI32U]
-- Int operations
builtinToPrimOp "Int.+" 2 = Just [I64Add]
builtinToPrimOp "Int.-" 2 = Just [I64Sub]
builtinToPrimOp "Int.*" 2 = Just [I64Mul]
builtinToPrimOp "Int./" 2 = Just [I64DivS]
builtinToPrimOp "Int.mod" 2 = Just [I64RemS]
builtinToPrimOp "Int.<=" 2 = Just [I64LeS, I64ExtendI32U]
builtinToPrimOp "Int.<" 2 = Just [I64LtS, I64ExtendI32U]
builtinToPrimOp "Int.==" 2 = Just [I64Eq, I64ExtendI32U]
-- Float operations
-- Operands are stored as i64 (reinterpreted), so we convert back to f64, do the op, then convert result to i64
-- Stack before: [i64_a, i64_b]
-- We need: f64.reinterpret_i64 on each operand before the float op
-- But we can't insert between operands with this approach, so we use a different strategy:
-- The caller (compileANormal for FComb) handles pushing operands as i64.
-- Float ops need to convert both operands. We handle this by emitting extra instructions.
builtinToPrimOp "Float.+" 2 = Just $ floatBinOp F64Add
builtinToPrimOp "Float.-" 2 = Just $ floatBinOp F64Sub
builtinToPrimOp "Float.*" 2 = Just $ floatBinOp F64Mul
builtinToPrimOp "Float./" 2 = Just $ floatBinOp F64Div
builtinToPrimOp "Float.<=" 2 = Just $ floatCmpOp F64Le
builtinToPrimOp "Float.<" 2 = Just $ floatCmpOp F64Lt
builtinToPrimOp "Float.==" 2 = Just $ floatCmpOp F64Eq
-- Unknown builtin
builtinToPrimOp _ _ = Nothing

-- | Generate instructions for a float binary operation.
-- Stack before: [i64_a, i64_b]  (floats stored as reinterpreted i64)
-- We need to convert both to f64, do the op, then convert result back to i64.
-- Uses a temp local to handle the stack manipulation.
floatBinOp :: WatInstr -> [WatInstr]
floatBinOp op =
  [ -- Stack: [i64_a, i64_b]
    -- Save b to temp, convert a, reload b as f64
    LocalSet "__float_temp"    -- Stack: [i64_a], temp = i64_b
  , F64ReinterpretI64          -- Stack: [f64_a]
  , LocalGet "__float_temp"    -- Stack: [f64_a, i64_b]
  , F64ReinterpretI64          -- Stack: [f64_a, f64_b]
  , op                         -- Stack: [f64_result]
  , I64ReinterpretF64          -- Stack: [i64_result]
  ]

-- | Generate instructions for a float comparison operation.
-- Same as floatBinOp but result is i32 (extended to i64).
floatCmpOp :: WatInstr -> [WatInstr]
floatCmpOp op =
  [ LocalSet "__float_temp"
  , F64ReinterpretI64
  , LocalGet "__float_temp"
  , F64ReinterpretI64
  , op                         -- Stack: [i32_result]
  , I64ExtendI32U              -- Stack: [i64_result]
  ]

--------------------------------------------------------------------------------
-- Foreign Function Imports (Phase 6)
--------------------------------------------------------------------------------

-- | Convert a ForeignFunc to a WASM import function name.
-- Dots and special chars are replaced with underscores to be WASM-compatible.
foreignFuncToImportName :: ForeignFunc -> String
foreignFuncToImportName ff =
  Text.unpack $ Text.map sanitize (foreignFuncBuiltinName ff)
  where
    sanitize '.' = '_'
    sanitize c = c

-- | Collect all foreign function calls from an ANormal term.
-- Returns a list of unique ForeignFuncs encountered.
collectForeignCalls :: (Var v) => ANormal Reference v -> [ForeignFunc]
collectForeignCalls = nub . go
  where
    go (TFOp ff _) = [ff]
    go (TLets _ _ _ binding body) = go binding ++ go body
    go (TMatch _ branches) = goBranches branches
    go (THnd _ _ _ body) = go body
    go (TShift _ _ body) = go body
    go (TKon _ _) = []  -- TKon just calls a continuation, no nested terms
    go (ABTN.Term _ (ABTN.Abs _ inner)) = go inner  -- Unwrap TAbs
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
    goBranches (MatchRequest _ _) = []  -- Request handlers are complex, skip for now
    goBranches (MatchText cases def) =
      concatMap go (Map.elems cases) ++ maybe [] go def
    goBranches (MatchSum cases) =
      -- MatchSum has EnumMap Word64 ([Mem], e)
      concatMap (\(_, (_, body)) -> go body) (EC.mapToList cases)

    nub = map head . groupBy (==) . sort

-- | Generate WatImport declarations for a list of foreign functions.
-- Each foreign function becomes: (import "unison" "funcName" (func $funcName ...))
foreignFuncsToImports :: [ForeignFunc] -> [WatImport]
foreignFuncsToImports = map toImport
  where
    toImport ff =
      let name = foreignFuncToImportName ff
          -- For now, assume all foreign funcs take i64 args and return i64
          -- TODO: Look up actual signature from ForeignFunc enum
          (params, results) = foreignFuncSignature ff
       in WatImport
            { importModule = "unison",
              importName = name,
              importKind = ImportFunc name params results
            }

-- | Get the WASM type signature for a foreign function.
-- For MVP, we use a simplified signature: all args as i64, returns i64.
-- A more complete implementation would look up the actual Unison type signature.
foreignFuncSignature :: ForeignFunc -> ([WatValType], [WatValType])
foreignFuncSignature _ff = ([I64], [I64])  -- Simplified: 1 arg, 1 result

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
-- Locals Save/Restore for Continuations
--------------------------------------------------------------------------------

-- | Generate instructions to save a single local to a Captured object
-- Each slot is 8 bytes (just the i64 value, simplified from TypedSlot)
saveLocalToCapture :: Int -> Int -> [WatInstr]
saveLocalToCapture _totalLocals localIdx =
  [ -- Store local value at slot offset in Captured
    -- Offset = capturedSlotsOffset + localIdx * 8
    LocalGet "__captured_ptr"
    , LocalGet ("p" ++ show localIdx)  -- Load the local value
    , I64Store (fromIntegral ABI.capturedSlotsOffset + fromIntegral localIdx * 8)
  ]

