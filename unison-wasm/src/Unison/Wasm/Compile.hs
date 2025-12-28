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
-- NOT YET supported (Phase 5+):
-- * Abilities/handlers
-- * Data constructors with fields
-- * Async foreign calls
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
    pattern TLets,
    pattern TLit,
    pattern TMatch,
    pattern TName,
    pattern TPrm,
    pattern TVar,
  )
import Unison.Runtime.ANF.POp (POp (..))
import Unison.Runtime.TypeTags (rawTag)
import Unison.Util.EnumContainers qualified as EC
import Unison.Var (Var)
import Unison.Var qualified as Var
import Unison.Wasm.ABI qualified as ABI
import Unison.Wasm.Compile.Primitives qualified as P
import Unison.Wasm.Compile.Runtime qualified as Runtime
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
    ctxRefNames :: Map Reference String,
    -- | Map from variable to function arity (for PAp creation)
    ctxFuncArities :: Map v Int,
    -- | Map from Reference to function arity (for lifted combinators)
    ctxRefArities :: Map Reference Int,
    -- | Map from Reference to function table index (for call_indirect)
    ctxRefTableIndices :: Map Reference Int
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
      ctxRefTableIndices = Map.empty
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
        moduleTableFuncs = tableFuncs
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

  pure
    WatModule
      { moduleMemory = Just 1, -- 1 page (64KB) for heap
        moduleGlobals = Runtime.runtimeGlobals,
        moduleFunctions = allFuncs,
        moduleExports = [exportName],
        moduleMemoryExport = Just "memory",
        moduleFuncTypes = Runtime.runtimeFuncTypes,
        moduleTableFuncs = tableFuncs
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
      -- Add __pap_temp for partial application handling
      funcLocals' = drop (length mems) (ctxLocals finalCtx) ++ [("__pap_temp", I32)]
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
        Just opInstr -> pure $ argInstrs ++ [opInstr]
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
-- For enums (no fields), just return the tag as i64
-- For data with fields, would need heap allocation (not yet implemented)
compileANormal _ctx (TApp (FCon _ref tag) []) = do
  -- Enum type: just return the constructor tag as i64
  pure [I64Const (rawTag tag)]

compileANormal _ctx (TApp (FCon _ref _tag) _args) = do
  -- Data type with fields requires heap allocation (not yet supported)
  Left $ UnsupportedConstruct "Data constructors with fields not yet supported"

-- Pattern match on integral values (MatchIntegral)
compileANormal ctx (TMatch v (MatchIntegral cases defaultCase)) = do
  compileIntegralMatch ctx v (EC.mapToList cases) defaultCase

-- Pattern match on boxed numeric values (MatchNumeric)
-- Same as MatchIntegral but for boxed data (produced by parser)
compileANormal ctx (TMatch v (MatchNumeric _ref cases defaultCase)) = do
  compileIntegralMatch ctx v (EC.mapToList cases) defaultCase

-- Pattern match on data types (MatchData) - sum type dispatch
-- For enums (no fields), dispatch on the tag value
compileANormal ctx (TMatch v (MatchData _ref cases defaultCase)) = do
  -- Convert MatchData cases to integral-style cases
  -- Each case is (CTag, ([Mem], body)) - for enums, [Mem] is empty
  let integralCases = [(rawTag tag, body) | (tag, ([], body)) <- EC.mapToList cases]
  -- Check if any case has fields (not supported yet)
  let casesWithFields = [(tag, mems) | (tag, (mems, _)) <- EC.mapToList cases, not (null mems)]
  if not (null casesWithFields)
    then Left $ UnsupportedConstruct "MatchData with field bindings not yet supported"
    else compileIfElseChain ctx v integralCases defaultCase

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

-- Fallback for unsupported constructs
compileANormal _ctx _term = do
  Left $ UnsupportedConstruct "Unsupported ANormal construct in Phase 4"

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
compileLit :: Lit Reference -> CompileResult [WatInstr]
compileLit (N n) = pure [I64Const n]
compileLit (I n) = pure [I64Const (fromIntegral n)]
compileLit (F f) = pure [F64Const f]
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
