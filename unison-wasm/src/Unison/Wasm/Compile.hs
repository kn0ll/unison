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
-- FUTURE:
-- * Async foreign calls with nested continuations
module Unison.Wasm.Compile
  ( -- * Compilation
    compileGroup,
    compileGroupWithLifted,
    compileMultipleWithLifted,
    CompileError (..),
    CompileResult,

    -- * Context (re-exported from Compile.Context)
    CompileCtx (..),
    emptyCtx,
    lookupVar,
    bindVars,
    setBaseLocalCount,
    getSaveableLocalCount,
    memToValType,
    refToFuncName,
    sanitizeName,

    -- * Foreign Calls
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
import Unison.Runtime.Foreign.Function.Type (ForeignFunc (..))
import Unison.Runtime.TypeTags (CTag, rawTag)
import Unison.Util.EnumContainers qualified as EC
import Unison.Var (Var)
import Unison.Var qualified as Var
import Unison.Wasm.ABI qualified as ABI
import Unison.Wasm.Compile.Async qualified as Async
import Unison.Wasm.Compile.Builtins qualified as Builtins
import Unison.Wasm.Compile.Context
  ( CompileCtx (..),
    emptyCtx,
    bindVars,
    lookupVar,
    setBaseLocalCount,
    getSaveableLocalCount,
    memToValType,
    refToFuncName,
    sanitizeName,
    allocYieldPoint,
  )
import Unison.Wasm.Compile.FFI qualified as FFI
import Unison.Wasm.Compile.Literal qualified as Literal
import Unison.Wasm.Compile.Match qualified as Match
import Unison.Wasm.Compile.Primitives qualified as P
import Unison.Wasm.Compile.Runtime qualified as Runtime
import Unison.Wasm.Emit (WatFunction (..), WatImport (..), WatInstr (..), WatModule (..), WatValType (..))

-- | Compilation errors
data CompileError
  = -- | Variable not found in context
    UnboundVariable Text
  | -- | Unsupported primitive operation
    UnsupportedPrimOp POp
  | -- | Unsupported construct
    UnsupportedConstruct Text
  | -- | Wrong number of arguments for primitive
    WrongArity POp Int Int -- expected, actual
  | -- | Foreign function call not supported
    UnsupportedForeign Text
  deriving (Eq, Show)

-- | Compilation result
type CompileResult a = Either CompileError a

-- Context types and functions are now in Compile.Context

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

  -- Collect FFI calls (foreign functions + debug primitives)
  let allForeignCalls = collectForeignCallsFromGroups (Rec localDefs entry) liftedGroups
      foreignImports = foreignFuncsToImports allForeignCalls
      allDebugBuiltins = collectDebugBuiltinsFromGroups (Rec localDefs entry) liftedGroups
      debugImports = debugBuiltinsToImports allDebugBuiltins
      imports = foreignImports ++ debugImports

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

-- | Compile multiple entry points into a single WASM module.
--
-- Each entry is a (Reference, SuperGroup, exportName) triple.
-- All entries share the same lifted combinators (dependencies).
compileMultipleWithLifted ::
  (Var v) =>
  [(Reference, SuperGroup Reference v, String)] ->
  [(Reference, SuperGroup Reference v)] ->
  CompileResult WatModule
compileMultipleWithLifted entries liftedGroups = do
  -- Build a map from Reference to function name for all lifted combinators AND entry points
  let liftedRefNames = [(ref, refToFuncName ref) | (ref, _) <- liftedGroups]
      entryRefNames = [(ref, exportName) | (ref, _, exportName) <- entries]
      refNames = Map.fromList (liftedRefNames ++ entryRefNames)

  -- Build a map from Reference to arity for all lifted combinators AND entry points
  let liftedArities = [(ref, superGroupArity sg) | (ref, sg) <- liftedGroups]
      entryArities = [(ref, superGroupArity sg) | (ref, sg, _) <- entries]
      refArities = Map.fromList (liftedArities ++ entryArities)

  -- Build a map from Reference to table index
  let liftedIndices = zip (map fst liftedGroups) [0..]
      entryIndices = zip [ref | (ref, _, _) <- entries] [length liftedGroups..]
      refTableIndices = Map.fromList (liftedIndices ++ entryIndices)

  -- Compile lifted combinators first
  liftedFuncs <- concat <$> mapM (compileLiftedGroup refNames refArities refTableIndices) liftedGroups

  -- Compile each entry point
  entryFuncsWithLocals <- mapM (\(_ref, Rec localDefs entry, exportName) -> do
    -- Build function name map for local definitions in this entry's group
    let funcNames = Map.fromList [(v, Text.unpack (Var.name v)) | (v, _) <- localDefs]
    let funcArities = Map.fromList [(v, superNormalArity sn) | (v, sn) <- localDefs]

    -- Compile local definitions
    localFuncs <- mapM (compileLocalDefWithRefCtx funcNames funcArities refNames refArities refTableIndices exportName) localDefs

    -- Compile entry function
    entryFunc <- compileSuperNormalWithRefCtx funcNames funcArities refNames refArities refTableIndices exportName entry exportName

    pure (localFuncs, entryFunc)) entries

  let allLocalFuncs = concatMap fst entryFuncsWithLocals
      allEntryFuncs = map snd entryFuncsWithLocals
      exportNames = [name | (_, _, name) <- entries]

  -- Merge: runtime + lifted functions + local functions + entry functions
  let allFuncs = Runtime.runtimeFunctions ++ liftedFuncs ++ allLocalFuncs ++ allEntryFuncs
      -- Build function table with all user functions (for call_indirect)
      userFuncs = liftedFuncs ++ allLocalFuncs ++ allEntryFuncs
      tableFuncs = map funcName userFuncs

  -- Collect FFI calls (foreign functions + debug primitives)
  let allForeignCalls = concatMap (\(_, sg, _) -> collectForeignCallsFromGroups sg liftedGroups) entries
      foreignImports = foreignFuncsToImports allForeignCalls
      allDebugBuiltins = concatMap (\(_, sg, _) -> collectDebugBuiltinsFromGroups sg liftedGroups) entries
      debugImports = debugBuiltinsToImports (nub allDebugBuiltins)
      imports = foreignImports ++ debugImports
      nub = map head . groupBy (==) . sort

  pure
    WatModule
      { moduleMemory = Just 1,
        moduleGlobals = Runtime.runtimeGlobals,
        moduleFunctions = allFuncs,
        moduleExports = exportNames ++ Runtime.runtimeExports,
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
        , ("__text_temp", I32)      -- Text literal allocation
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
        , ("__ffi_result", I64)     -- TFOp: FFI result for yield check
        , ("__async_locals_ptr", I32) -- TFOp: Pointer to saved locals array
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
        , ("__text_temp", I32)      -- Text literal allocation
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
        , ("__ffi_result", I64)     -- TFOp: FFI result for yield check
        , ("__async_locals_ptr", I32) -- TFOp: Pointer to saved locals array
        ]

      -- Check if this function has yield points and needs state machine transformation
      hasAsync = Async.hasYieldPoints bodyInstrs

      -- Add state machine locals if needed
      asyncLocals = if hasAsync
        then [("__state", I32)]  -- State variable for state machine
        else []

      -- Locals are all variables bound after the parameters plus helpers
      funcLocals' = drop (length mems) (ctxLocals finalCtx) ++ helperLocals ++ asyncLocals
      funcResults = [I64] -- All functions return i64 (boxed values or unboxed integers)

      -- Apply state machine transformation if function has yield points
      transformedBody = if hasAsync
        then Async.transformToStateMachine funcLocals' bodyInstrs
        else bodyInstrs

  pure
    WatFunction
      { funcName = name,
        funcParams = funcParams,
        funcLocals = funcLocals',
        funcResults = funcResults,
        funcBody = transformedBody
      }

-- | Unwrap nested TAbs to get variable bindings and inner term
unabss :: (Var v) => ANormal Reference v -> ([v], ANormal Reference v)
unabss (ABTN.TAbs v (unabss -> (vs, bd))) = (v : vs, bd)
unabss bd = ([], bd)

--------------------------------------------------------------------------------
-- ANormal Compilation
--------------------------------------------------------------------------------

-- | Compile an ANormal term to WASM instructions (returns updated context for locals)
-- This is just an alias for compileANormal now that it returns the context.
compileANormalWithCtx ::
  (Var v) =>
  CompileCtx v ->
  ANormal Reference v ->
  CompileResult ([WatInstr], CompileCtx v)
compileANormalWithCtx = compileANormal

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
collectLocals ctx (TMatch _ (MatchData _ref cases defaultCase)) =
  -- Collect from all branches, including field bindings for each case
  let collectCase (_, (mems, body)) c =
        -- Extract field variables from TAbs wrappers and bind them
        let (fieldVars, innerBody) = Match.extractAbsVars body
            fieldBindings = zip fieldVars mems
            c' = if null mems then c else bindVars fieldBindings c
         in collectLocals c' innerBody
      ctxFromCases = foldr collectCase ctx (EC.mapToList cases)
   in case defaultCase of
        Just defBody -> collectLocals ctxFromCases defBody
        Nothing -> ctxFromCases
collectLocals ctx (TMatch _ (MatchRequest abilityBranches pureCase)) =
  -- Collect from pure case and all ability branches
  let collectAbility (_ref, tagCases) c =
        foldr (\(_, (mems, body)) c' ->
          let (fieldVars, innerBody) = Match.extractAbsVars body
              fieldBindings = zip fieldVars mems
              c'' = if null mems then c' else bindVars fieldBindings c'
           in collectLocals c'' innerBody) c (EC.mapToList tagCases)
      ctxFromBranches = foldr collectAbility ctx abilityBranches
   in collectLocals ctxFromBranches pureCase
-- THnd: collect from the handler body
collectLocals ctx (THnd _refs _handlerVar _affineHandler body) =
  collectLocals ctx body
-- TShift: bind the continuation variable and collect from body
collectLocals ctx (TShift _ref contVar body) =
  let ctx' = bindVars [(contVar, BX)] ctx
   in collectLocals ctx' body
collectLocals ctx _ = ctx

-- | Compile an ANormal term to WASM instructions
-- Returns instructions and updated context (for yield point tracking)
compileANormal ::
  (Var v) =>
  CompileCtx v ->
  ANormal Reference v ->
  CompileResult ([WatInstr], CompileCtx v)
-- Let binding: evaluate binding, store in local, continue with body
compileANormal ctx (TLets _direct letVars mems binding body) = do
  -- Compile the binding expression
  (bindingInstrs, ctx1) <- compileANormal ctx binding

  -- Extend context with new variables
  let ctx2 = bindVars (zip letVars mems) ctx1

  -- Get the local indices for storing results
  let storeInstrs = case letVars of
        (v : _) -> case lookupVar v ctx2 of
          Just (i, _) ->
            -- Store result in local (for single-result expressions)
            [LocalSet ("p" ++ show i)]
          Nothing -> []
        [] -> []

  -- Compile the body
  (bodyInstrs, ctx3) <- compileANormal ctx2 body

  pure (bindingInstrs ++ storeInstrs ++ bodyInstrs, ctx3)

-- Variable reference: push value onto stack
compileANormal ctx (TVar v) = do
  case lookupVar v ctx of
    Just (i, _) -> pure ([LocalGet ("p" ++ show i)], ctx)
    Nothing -> Left $ UnboundVariable (Var.name v)

-- Literal: push constant onto stack
compileANormal ctx (TLit lit) = do
  instrs <- compileLit lit
  pure (instrs, ctx)

-- Boxed literal: same as TLit for now (heap alloc for sum types handled separately)
compileANormal ctx (TBLit lit) = do
  instrs <- compileLit lit
  pure (instrs, ctx)

-- Primitive operation
compileANormal ctx (TPrm op args) = do
  -- Compile arguments (push onto stack)
  (argInstrs, ctx1) <- compileArgs ctx args
  -- Special case: Debug operations are FFI calls that need yield check
  case op of
    TRCE -> do
      let (yieldId, ctx2) = allocYieldPoint ctx1
          allLocals = ctxLocals ctx2
      pure (argInstrs ++ ffiCallWithYieldCheckFull "Debug_trace" (ctxFuncTableIdx ctx2) yieldId allLocals, ctx2)
    PRNT -> do
      let (yieldId, ctx2) = allocYieldPoint ctx1
          allLocals = ctxLocals ctx2
      pure (argInstrs ++ ffiCallWithYieldCheckFull "Debug_watch" (ctxFuncTableIdx ctx2) yieldId allLocals, ctx2)
    _ -> do
      -- Regular primitive - emit single instruction
      opInstr <- compilePrimOp op (length args)
      pure (argInstrs ++ [opInstr], ctx1)

-- Static function call (FComb) - handle builtins specially
-- Also handles partial application when args.length < arity
compileANormal ctx (TApp (FComb ref) args) = do
  -- Compile arguments
  (argInstrs, ctx1) <- compileArgs ctx args
  let numArgs = length args
  case ref of
    -- Builtin references: map to primitive operations or foreign functions
    Reference.Builtin name -> do
      -- Special case: Debug builtins are FFI calls that need yield check
      case name of
        "Debug.trace" -> do
          let (yieldId, ctx2) = allocYieldPoint ctx1
              allLocals = ctxLocals ctx2
          pure (argInstrs ++ ffiCallWithYieldCheckFull "Debug_trace" (ctxFuncTableIdx ctx2) yieldId allLocals, ctx2)
        "Debug.watch" -> do
          let (yieldId, ctx2) = allocYieldPoint ctx1
              allLocals = ctxLocals ctx2
          pure (argInstrs ++ ffiCallWithYieldCheckFull "Debug_watch" (ctxFuncTableIdx ctx2) yieldId allLocals, ctx2)
        _ ->
          -- Try to map builtin to primitive op
          case builtinToPrimOp name numArgs of
            Just opInstrs -> pure (argInstrs ++ opInstrs, ctx1)
            Nothing ->
              -- Check if it's a foreign function
              case builtinNameToForeignFunc name of
                Just ff -> do
                  -- Foreign function call - emit import call with yield check
                  let funcName = foreignFuncToImportName ff
                      (yieldId, ctx2) = allocYieldPoint ctx1
                      allLocals = ctxLocals ctx2
                  pure (argInstrs ++ ffiCallWithYieldCheckFull funcName (ctxFuncTableIdx ctx2) yieldId allLocals, ctx2)
                Nothing ->
                  -- Unknown builtin
                  Left $ UnsupportedConstruct $ "Unknown builtin: " <> name
    -- Derived reference: look up in refNames for lifted combinators
    Reference.DerivedId _ -> do
      case Map.lookup ref (ctxRefNames ctx1) of
        Just funcName -> do
          -- Check if this is a partial application
          case Map.lookup ref (ctxRefArities ctx1) of
            Just arity | numArgs < arity ->
              -- Partial application: create a PAp and store args
              -- Use table index for call_indirect
              let tableIdx = Map.lookup ref (ctxRefTableIndices ctx1)
              in case tableIdx of
                   Just idx -> do
                     -- Allocate PAp, store captured args, then convert to i64
                     -- Use __pap_temp local (must be declared in the function)
                     let tempName = "__pap_temp"
                     storeInstrs <- storePApArgs ctx1 tempName 0 args
                     pure
                       ( -- Don't use argInstrs - we read from locals in storePApArgs
                         [ I32Const (fromIntegral idx)
                         , I32Const (fromIntegral arity)
                         , I32Const (fromIntegral numArgs)
                         , Call "__alloc_pap"
                         , LocalSet tempName  -- Store PAp pointer
                         ]
                         ++ storeInstrs  -- Store captured args
                         ++ [LocalGet tempName, I64ExtendI32U]  -- Get pointer and extend to i64
                       , ctx1
                       )
                   Nothing ->
                     Left $ UnsupportedConstruct $ "No table index for reference in partial application"
            _ ->
              -- Full application: direct call
              pure (argInstrs ++ [Call funcName], ctx1)
        Nothing ->
          -- Not found in refNames - might be self-recursion
          let funcName = if null (ctxCurrentFunc ctx1) then "target" else ctxCurrentFunc ctx1
           in pure (argInstrs ++ [Call funcName], ctx1)

-- Function variable call (FVar) - call local combinator or PAp
compileANormal ctx (TApp (FVar v) args) = do
  -- Look up the function name in the context
  case Map.lookup v (ctxFuncNames ctx) of
    Just funcName -> do
      -- Known combinator - direct call
      (argInstrs, ctx1) <- compileArgs ctx args
      pure (argInstrs ++ [Call funcName], ctx1)
    Nothing ->
      -- Not a known combinator - must be a local variable holding a PAp
      case lookupVar v ctx of
        Just (localIdx, _) -> do
          -- This is a local variable holding a PAp pointer
          -- We need to dynamically dispatch: load captured args + new args, then call_indirect
          (argInstrs, ctx1) <- compileArgs ctx args
          let numNewArgs = length args
              papLocal = "p" ++ show localIdx
          -- Generate code to invoke the PAp with new arguments
          pure (compileApplyPAp papLocal numNewArgs argInstrs, ctx1)
        Nothing ->
          Left $ UnboundVariable (Var.name v)

-- Data constructor application (FCon) - create enum/data values
-- Enums (no fields): return the tag as i64
-- Data1 (1 field): allocate heap object
-- Data2 (2 fields): allocate heap object
-- DataG (3+ fields): allocate heap object
compileANormal ctx (TApp (FCon _ref tag) []) = do
  -- Enum type: just return the constructor tag as i64
  pure ([I64Const (rawTag tag)], ctx)

compileANormal ctx (TApp (FCon ref tag) [arg1]) = do
  -- Data1: one field
  (argInstrs, ctx1) <- compileANormal ctx (TVar arg1)
  let typeRef = refToI32 ref
      ctorId = fromIntegral (rawTag tag) :: Word32
      argTag = getVarTypeTag ctx1 arg1
  pure
    ( [ I32Const typeRef,
        I32Const ctorId,
        I32Const argTag -- field0 TypeTag
      ]
        ++ argInstrs -- field0 value on stack
        ++ [Call "__alloc_data1"]
        ++ P.extendPtrToI64 -- Return as i64
    , ctx1
    )

compileANormal ctx (TApp (FCon ref tag) [arg1, arg2]) = do
  -- Data2: two fields
  (arg1Instrs, ctx1) <- compileANormal ctx (TVar arg1)
  (arg2Instrs, ctx2) <- compileANormal ctx1 (TVar arg2)
  let typeRef = refToI32 ref
      ctorId = fromIntegral (rawTag tag) :: Word32
      arg1Tag = getVarTypeTag ctx2 arg1
      arg2Tag = getVarTypeTag ctx2 arg2
  pure
    ( [ I32Const typeRef,
        I32Const ctorId,
        I32Const arg1Tag
      ]
        ++ arg1Instrs
        ++ [I32Const arg2Tag]
        ++ arg2Instrs
        ++ [Call "__alloc_data2"]
        ++ P.extendPtrToI64 -- Return as i64
    , ctx2
    )

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
  pure
    ( allocInstrs
        ++ storeInstrs
        ++ [LocalGet "__datag_temp"]
        ++ P.extendPtrToI64
    , ctx
    )

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
  (argInstrs, ctx1) <- compileArgs ctx args

  pure
    ( [ Comment $ "TReq: Ability request"
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
    , ctx1
    )

-- Pattern match on integral values (MatchIntegral)
compileANormal ctx (TMatch v (MatchIntegral cases defaultCase)) = do
  compileIntegralMatchWithCtx ctx v (EC.mapToList cases) defaultCase

-- Pattern match on boxed numeric values (MatchNumeric)
-- Same as MatchIntegral but for boxed data (produced by parser)
compileANormal ctx (TMatch v (MatchNumeric _ref cases defaultCase)) = do
  compileIntegralMatchWithCtx ctx v (EC.mapToList cases) defaultCase

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
      compileIntegralMatchWithCtx ctx v enumCases defaultCase
    else -- Mixed cases with field bindings
      compileDataMatchWithCtx ctx v allCases defaultCase

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
      (pureCaseInstrs, ctx1) <- compileANormal ctx pureCase

      -- For MVP: generate if-else chain for ability branches
      (branchInstrs, ctx2) <- compileRequestBranchesWithCtx ctx1 scrutLocal abilityBranches

      pure
        ( [ Comment "MatchRequest: Match on ability request"
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
        , ctx2
        )

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
  (bodyInstrs, finalCtx) <- compileANormal newCtx bo

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

  pure (allocInstrs ++ storeInstrs ++ bodyInstrs, finalCtx)

--------------------------------------------------------------------------------
-- Ability Handler Constructs
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
      (bodyInstrs, ctx1) <- compileANormal ctx body

      -- Generate instructions to insert handler into denv for each ability
      let insertHandlerInstrs refVal =
            [ GlobalGet "denv_ptr"  -- Current denv
            , I32Const refVal        -- Ability key
            , LocalGet handlerLocal
            , I32WrapI64             -- Handler pointer
            , Call "__denv_insert"
            , GlobalSet "denv_ptr"   -- Update denv with new handler
            ]

      -- Insert handler for all abilities (multi-ability support)
      let allInsertInstrs = concatMap insertHandlerInstrs abilityRefs

      -- Generate: install handler, push Mark frame, run body, pop Mark frame, restore denv
      pure
        ( [ Comment "THnd: Install ability handler"
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
        , ctx1
        )

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
  (bodyInstrs, ctx1) <- compileANormal newCtx body

  -- Generate continuation capture code
  -- We need helper locals for the walk:
  -- __k_walk: current frame being examined
  -- __k_start: where we started (to store in Captured)
  -- __mark_ptr: the Mark frame when found
  pure
    ( [ Comment $ "TShift: Capture continuation for ability " ++ show abilityRef
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
    , ctx1
    )

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
      (argInstrs, ctx1) <- compileArgs ctx args

      pure
        ( [ Comment "TKon: Resume captured continuation"
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
        , ctx1
        )
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
-- After the call, we check if the result is YIELD_SENTINEL.
-- If so, we propagate the yield by returning YIELD_SENTINEL.
-- This enables async FFI: JavaScript returns YIELD_SENTINEL immediately,
-- and later calls __resume to continue the computation.
compileANormal ctx (TFOp foreignFunc args) = do
  -- Compile arguments (push onto stack as i64)
  (argInstrs, ctx1) <- compileArgs ctx args
  -- Call the imported function using its sanitized name
  let funcName = foreignFuncToImportName foreignFunc
      (yieldId, ctx2) = allocYieldPoint ctx1
      allLocals = ctxLocals ctx2
  pure (argInstrs ++ ffiCallWithYieldCheckFull funcName (ctxFuncTableIdx ctx2) yieldId allLocals, ctx2)

-- Fallback for unsupported constructs
compileANormal ctx _term = do
  pure ([Comment "Unsupported ANormal construct", Unreachable], ctx)

-- | Compile a list of variable arguments, threading context through
compileArgs :: (Var v) => CompileCtx v -> [v] -> CompileResult ([WatInstr], CompileCtx v)
compileArgs ctx [] = pure ([], ctx)
compileArgs ctx (v:vs) = do
  (instrs1, ctx1) <- compileANormal ctx (TVar v)
  (instrs2, ctx2) <- compileArgs ctx1 vs
  pure (instrs1 ++ instrs2, ctx2)

--------------------------------------------------------------------------------
-- FFI Call Helpers
--------------------------------------------------------------------------------

-- | Generate instructions for an FFI call with full yield handling.
--
-- This version saves all locals when yielding, enabling proper resumption.
-- Parameters:
-- * funcName - the FFI function to call
-- * funcTableIdx - this function's index in the function table
-- * yieldPointId - unique ID for this yield point (for br_table resume)
-- * localNames - list of (name, type) for all locals to save
--
-- The generated code includes YieldPointStart/YieldPointEnd markers that are
-- processed by the state machine transformation in compileSuperNormal.
ffiCallWithYieldCheckFull ::
  String ->          -- FFI function name
  Int ->             -- Function table index
  Int ->             -- Yield point ID
  [(String, WatValType)] -> -- All locals to save
  [WatInstr]
ffiCallWithYieldCheckFull funcName funcTableIdx yieldPointId locals =
  let localsCount = length locals
      -- Generate instructions to save each local to the locals array
      -- Array layout: locals[i] at offset i*8
      saveLocals = concatMap saveLocal (zip [0..] locals)
      saveLocal (idx, (name, _)) =
        [ LocalGet "__async_locals_ptr",
          LocalGet name,
          I64Store (fromIntegral (idx * 8 :: Int))
        ]
  in
  [ -- Mark start of yield point (for state machine transformation)
    YieldPointStart yieldPointId,
    Call funcName,
    -- Save result to local, keep on stack for comparison
    LocalTee "__ffi_result",
    -- Compare with YIELD_SENTINEL
    I64Const ABI.yieldSentinel,
    I64Eq,
    -- If equal, save state and return YIELD_SENTINEL
    IfVoid
      ( [ Comment $ "FFI yielded - saving " ++ show localsCount ++ " locals",
          -- Allocate locals array
          I32Const (fromIntegral localsCount),
          Call "__alloc_locals_array",
          LocalSet "__async_locals_ptr"
        ]
        ++ saveLocals
        ++ [ -- Generate unique continuation ID
             GlobalGet "async_cont_id",
             I64Const 1,
             I64Add,
             GlobalSet "async_cont_id",
             -- Create AsyncCont object
             GlobalGet "async_cont_id",  -- cont_id
             GlobalGet "k_ptr",          -- k_ptr
             GlobalGet "denv_ptr",       -- denv_ptr (for handler preservation)
             LocalGet "__async_locals_ptr",  -- locals_ptr
             I32Const (fromIntegral localsCount),  -- locals_count
             I32Const (fromIntegral funcTableIdx), -- func_idx
             I32Const (fromIntegral yieldPointId), -- resume_label
             Call "__alloc_async_cont",
             GlobalSet "async_cont_ptr",
             -- Return YIELD_SENTINEL
             I64Const ABI.yieldSentinel,
             Return
           ]
      )
      [],
    -- Mark end of yield point (resume point - code after this uses __ffi_result)
    YieldPointEnd yieldPointId,
    -- Normal path: restore result to stack
    LocalGet "__ffi_result"
  ]

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

--------------------------------------------------------------------------------
-- Pattern Matching (delegated to Compile.Match)
--------------------------------------------------------------------------------

-- | Adapter to convert Match.CompileError to our CompileError
adaptMatchError :: Match.CompileError -> CompileError
adaptMatchError (Match.UnsupportedConstruct msg) = UnsupportedConstruct msg

-- | Helper to adapt the new compileANormal signature for Match functions
-- Match functions expect CompileResult [WatInstr], but compileANormal returns
-- CompileResult ([WatInstr], CompileCtx v). We extract just the instructions.
compileANormalForMatch :: (Var v) => CompileCtx v -> ANormal Reference v -> Either Match.CompileError [WatInstr]
compileANormalForMatch ctx term = case compileANormal ctx term of
  Left err -> Left $ Match.UnsupportedConstruct (Text.pack (show err))
  Right (instrs, _) -> Right instrs

-- | Compile MatchIntegral/MatchNumeric with full multi-case support
compileIntegralMatch ::
  (Var v) =>
  CompileCtx v ->
  v ->
  [(Word64, ANormal Reference v)] ->
  Maybe (ANormal Reference v) ->
  CompileResult [WatInstr]
compileIntegralMatch ctx scrutVar cases mDefault =
  case Match.compileIntegralMatch compileANormalForMatch ctx scrutVar cases mDefault of
    Left err -> Left $ adaptMatchError err
    Right instrs -> Right instrs

-- | Compile MatchIntegral/MatchNumeric with context threading
compileIntegralMatchWithCtx ::
  (Var v) =>
  CompileCtx v ->
  v ->
  [(Word64, ANormal Reference v)] ->
  Maybe (ANormal Reference v) ->
  CompileResult ([WatInstr], CompileCtx v)
compileIntegralMatchWithCtx ctx scrutVar cases mDefault = do
  instrs <- compileIntegralMatch ctx scrutVar cases mDefault
  -- Thread context through all branches to collect yield points
  let ctx' = foldr (\(_, body) c -> collectLocals c body) ctx cases
      ctx'' = case mDefault of
                Just defBody -> collectLocals ctx' defBody
                Nothing -> ctx'
  -- Take the maximum yield point from all branches
  let allContexts = map (\(_, body) -> collectYieldPoints ctx body) cases
      maxYieldId = maximum (0 : map ctxNextYieldPoint allContexts)
      finalCtx = ctx'' { ctxNextYieldPoint = maxYieldId }
  pure (instrs, finalCtx)
  where
    collectYieldPoints :: (Var v) => CompileCtx v -> ANormal Reference v -> CompileCtx v
    collectYieldPoints c body = case compileANormal c body of
      Right (_, c') -> c'
      Left _ -> c

-- | Compile MatchData with potential field bindings
compileDataMatch ::
  (Var v) =>
  CompileCtx v ->
  v ->
  [(CTag, ([Mem], ANormal Reference v))] ->
  Maybe (ANormal Reference v) ->
  CompileResult [WatInstr]
compileDataMatch ctx scrutVar cases mDefault =
  case Match.compileDataMatch compileANormalForMatch ctx scrutVar cases mDefault of
    Left err -> Left $ adaptMatchError err
    Right instrs -> Right instrs

-- | Compile MatchData with context threading
compileDataMatchWithCtx ::
  (Var v) =>
  CompileCtx v ->
  v ->
  [(CTag, ([Mem], ANormal Reference v))] ->
  Maybe (ANormal Reference v) ->
  CompileResult ([WatInstr], CompileCtx v)
compileDataMatchWithCtx ctx scrutVar cases mDefault = do
  instrs <- compileDataMatch ctx scrutVar cases mDefault
  -- Thread context through all branches to collect yield points
  let ctx' = foldr (\(_, (_, body)) c -> collectLocals c body) ctx cases
      ctx'' = case mDefault of
                Just defBody -> collectLocals ctx' defBody
                Nothing -> ctx'
  let allContexts = map (\(_, (_, body)) -> collectYieldPoints ctx body) cases
      maxYieldId = maximum (0 : map ctxNextYieldPoint allContexts)
      finalCtx = ctx'' { ctxNextYieldPoint = maxYieldId }
  pure (instrs, finalCtx)
  where
    collectYieldPoints :: (Var v) => CompileCtx v -> ANormal Reference v -> CompileCtx v
    collectYieldPoints c body = case compileANormal c body of
      Right (_, c') -> c'
      Left _ -> c

-- | Compile ability request branches for MatchRequest
compileRequestBranches ::
  (Var v) =>
  CompileCtx v ->
  String ->
  [(Reference, EC.EnumMap CTag ([Mem], ANormal Reference v))] ->
  CompileResult [WatInstr]
compileRequestBranches ctx scrutLocal branches =
  case Match.compileRequestBranches compileANormalForMatch ctx scrutLocal branches of
    Left err -> Left $ adaptMatchError err
    Right instrs -> Right instrs

-- | Compile ability request branches with context threading
compileRequestBranchesWithCtx ::
  (Var v) =>
  CompileCtx v ->
  String ->
  [(Reference, EC.EnumMap CTag ([Mem], ANormal Reference v))] ->
  CompileResult ([WatInstr], CompileCtx v)
compileRequestBranchesWithCtx ctx scrutLocal branches = do
  instrs <- compileRequestBranches ctx scrutLocal branches
  -- Thread context through all branches
  let collectFromBranches (_, tagMap) c =
        foldr (\(_, (_, body)) c' -> collectLocals c' body) c (EC.mapToList tagMap)
      ctx' = foldr collectFromBranches ctx branches
  pure (instrs, ctx')

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
-- Literal compilation is now in Compile.Literal
compileLit :: Lit Reference -> CompileResult [WatInstr]
compileLit lit = case Literal.compileLit lit of
  Left (Literal.UnsupportedLiteral msg) -> Left $ UnsupportedConstruct (Text.pack msg)
  Right instrs -> Right instrs

--------------------------------------------------------------------------------
-- Primitive Operation Compilation (delegated to Compile.Builtins)
--------------------------------------------------------------------------------

-- | Compile a primitive operation to a WASM instruction
compilePrimOp :: POp -> Int -> CompileResult WatInstr
compilePrimOp op n = case Builtins.compilePrimOp op n of
  Left (Builtins.UnsupportedPrimOp p) -> Left $ UnsupportedPrimOp p
  Right instr -> Right instr

-- | Map builtin reference names to WASM instructions
builtinToPrimOp :: Text -> Int -> Maybe [WatInstr]
builtinToPrimOp = Builtins.builtinToPrimOp

--------------------------------------------------------------------------------
-- Foreign Function Imports (delegated to Compile.FFI)
--------------------------------------------------------------------------------

-- | Convert a ForeignFunc to a WASM import function name.
foreignFuncToImportName :: ForeignFunc -> String
foreignFuncToImportName = FFI.foreignFuncToImportName

-- | Look up a builtin name and return the ForeignFunc if it exists.
builtinNameToForeignFunc :: Text -> Maybe ForeignFunc
builtinNameToForeignFunc = FFI.builtinNameToForeignFunc

-- | Collect all foreign function calls from an ANormal term.
collectForeignCalls :: (Var v) => ANormal Reference v -> [ForeignFunc]
collectForeignCalls = FFI.collectForeignCalls

-- | Collect foreign calls from a main SuperGroup and its lifted combinators.
collectForeignCallsFromGroups ::
  (Var v) =>
  SuperGroup Reference v ->
  [(Reference, SuperGroup Reference v)] ->
  [ForeignFunc]
collectForeignCallsFromGroups = FFI.collectForeignCallsFromGroups

-- | Generate WatImport declarations for a list of foreign functions.
foreignFuncsToImports :: [ForeignFunc] -> [WatImport]
foreignFuncsToImports = FFI.foreignFuncsToImports

-- | Collect debug builtins from all groups.
collectDebugBuiltinsFromGroups ::
  (Var v) =>
  SuperGroup Reference v ->
  [(Reference, SuperGroup Reference v)] ->
  [Text]
collectDebugBuiltinsFromGroups = FFI.collectDebugBuiltinsFromGroups

-- | Generate imports for debug builtins.
debugBuiltinsToImports :: [Text] -> [WatImport]
debugBuiltinsToImports = FFI.debugBuiltinsToImports

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

