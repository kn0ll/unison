{-# LANGUAGE OverloadedStrings #-}

-- | Codebase integration for WASM compilation.
--
-- This module provides the ability to look up terms by name or hash from
-- a Unison codebase and compile them (with all dependencies) to WASM.
--
-- Usage:
--   result <- compileFromCodebase codebase (ByName "calculatePrice") "calculatePrice"
--   case result of
--     Right wasm -> putStr (emitModule wasm)
--     Left err -> die (show err)
module Unison.Wasm.Codebase
  ( -- * Main entry point
    compileFromCodebase,
    compileFromTypecheckedFile,
    compileFromCodebasePath,
    compileMultipleFromCodebasePath,

    -- * Types
    CompileTarget (..),
    CodebaseError (..),

    -- * Lower-level operations
    resolveName,
    resolveTarget,
    collectDependencies,
    loadTermsWithDependencies,
    loadProjectBranchNames,
  )
where

import Control.Monad.Except (ExceptT (..), runExceptT)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import U.Codebase.Sqlite.Project (Project (..))
import U.Codebase.Sqlite.ProjectBranch (ProjectBranch (..))
import U.Codebase.Sqlite.Queries qualified as Q
import Unison.Builtin qualified as Builtin
import Unison.Codebase qualified as Codebase
import Unison.Codebase.Branch qualified as Branch
import Unison.Codebase.Branch.Names qualified as Branch
import Unison.Codebase.CodeLookup qualified as CL
import Unison.Codebase.Init (CodebaseLockOption (..), MigrationStrategy (..), Init (..))
import Unison.Codebase.SqliteCodebase qualified as SC
import Unison.Codebase.Type (Codebase (..))
import Unison.ConstructorReference (ConstructorReference, GConstructorReference (..))
import Unison.Core.Project (ProjectName (..), ProjectBranchName (..))
import Unison.HashQualified qualified as HQ
import Unison.Names (Names)
import Unison.NamesWithHistory qualified as Names
import Unison.Parser.Ann (Ann)
import Unison.Prelude
import Unison.Reference (Reference)
import Unison.Reference qualified as Reference
import Unison.Referent qualified as Referent
import Unison.Runtime.ANF (SuperGroup, addDefaultCases, inlineAlias, lamLift, saturate, superNormalize)
import Unison.Runtime.IOSource qualified as IOSource
import Unison.Runtime.Pattern (DataSpec, builtinDataSpec, splitPatterns)
import Unison.Symbol (Symbol)
import Unison.Syntax.Name qualified as Name (parseText)
import Unison.Term (Term)
import Unison.Term qualified as Term
import Unison.UnisonFile.Names qualified as UF (typecheckedToNames)
import Unison.UnisonFile.Type (TypecheckedUnisonFile)
import Unison.UnisonFile qualified as UF
import Unison.Wasm.Compile (CompileError, compileGroupWithLifted, compileMultipleWithLifted)
import Unison.Wasm.Emit (WatModule)

-- | What to compile - either by name or by hash
data CompileTarget
  = -- | Look up a term by name (e.g., "calculatePrice" or "myLib.math.add")
    ByName Text
  | -- | Look up a term by reference (already resolved)
    ByReference Reference
  deriving (Eq, Show)

-- | Possible errors during codebase compilation
data CodebaseError
  = -- | The requested term was not found
    TermNotFound CompileTarget
  | -- | Multiple terms match the name
    AmbiguousName Text [Reference]
  | -- | A dependency could not be loaded
    DependencyMissing Reference
  | -- | Compilation failed
    CompilationFailed CompileError
  | -- | No terms found in the file
    NoTermsInFile
  | -- | Could not open the codebase at the given path
    CodebaseOpenError FilePath Text
  | -- | Project not found in codebase
    ProjectNotFound Text
  | -- | Branch not found in project
    BranchNotFound Text Text
  deriving (Eq, Show)

-- -----------------------------------------------------------------------------
-- Utilities
-- -----------------------------------------------------------------------------

-- | Convert a DataSpec to a map from ConstructorReference to arity.
-- This is used by `saturate` to know how many args each constructor needs.
-- (Copied from Unison.Runtime.Interface to avoid heavy dependency)
uncurryDspec :: DataSpec -> Map ConstructorReference Int
uncurryDspec = Map.fromList . concatMap f . Map.toList
  where
    f (r, l) = zipWith (\n c -> (ConstructorReference r n, c)) [0 ..] $ either id id l

-- -----------------------------------------------------------------------------
-- Phase 1: Codebase Access
-- -----------------------------------------------------------------------------

-- | Create a CodeLookup from a codebase.
-- This is used to look up terms, types, and type declarations.
codebaseToCodeLookup :: (MonadIO m) => Codebase m Symbol Ann -> CL.CodeLookup Symbol m Ann
codebaseToCodeLookup c =
  CL.CodeLookup
    { CL.getTerm = goGetTerm,
      CL.getTypeOfTerm = goGetTypeOfTerm,
      CL.getTypeDeclaration = goGetTypeDecl
    }
    <> Builtin.codeLookup
    <> IOSource.codeLookupM
  where
    goGetTerm = Codebase.runTransaction c . getTerm c
    goGetTypeOfTerm = Codebase.runTransaction c . getTypeOfTermImpl c
    goGetTypeDecl = Codebase.runTransaction c . getTypeDeclaration c

-- | Resolve a name to a Reference in the given Names.
resolveName :: Names -> Text -> Either CodebaseError Reference
resolveName names nameText =
  case Name.parseText nameText of
    Nothing -> Left (TermNotFound (ByName nameText))
    Just name ->
      let hqName = HQ.NameOnly name
          refs = Names.lookupHQTerm Names.IncludeSuffixes hqName names
       in case toList refs of
            [] -> Left (TermNotFound (ByName nameText))
            [Referent.Ref ref] -> Right ref
            [Referent.Con _ _] -> Left (TermNotFound (ByName nameText)) -- Constructors not supported yet
            multiple ->
              let termRefs = mapMaybe toRef multiple
               in Left (AmbiguousName nameText termRefs)
  where
    toRef (Referent.Ref r) = Just r
    toRef _ = Nothing

-- | Resolve a CompileTarget to a Reference.
resolveTarget :: Names -> CompileTarget -> Either CodebaseError Reference
resolveTarget names target = case target of
  ByName nameText -> resolveName names nameText
  ByReference ref -> Right ref

-- -----------------------------------------------------------------------------
-- Phase 2: Dependency Resolution
-- -----------------------------------------------------------------------------

-- | Collect all transitive term dependencies for a reference.
-- Returns the set of all Reference.Ids that need to be loaded.
collectDependencies ::
  CL.CodeLookup Symbol IO Ann ->
  Reference ->
  IO (Set Reference.Id)
collectDependencies codeLookup ref = case ref of
  Reference.Builtin _ -> pure Set.empty -- Builtins are handled separately
  Reference.DerivedId refId ->
    CL.transitiveDependencies codeLookup Set.empty refId

-- | Load all terms for the given references.
loadTerms ::
  CL.CodeLookup Symbol IO Ann ->
  Set Reference.Id ->
  IO (Map Reference (Term Symbol Ann))
loadTerms codeLookup refIds = do
  pairs <- forM (toList refIds) $ \refId -> do
    mTerm <- CL.getTerm codeLookup refId
    pure $ (Reference.DerivedId refId,) <$> mTerm
  pure $ Map.fromList (catMaybes pairs)

-- | Load a term and all its dependencies from a codebase.
loadTermsWithDependencies ::
  CL.CodeLookup Symbol IO Ann ->
  Reference ->
  IO (Either CodebaseError (Map Reference (Term Symbol Ann)))
loadTermsWithDependencies codeLookup ref = do
  -- First, collect all dependencies
  deps <- collectDependencies codeLookup ref

  -- Add the main reference if it's not a builtin
  let allRefs = case ref of
        Reference.Builtin _ -> deps
        Reference.DerivedId refId -> Set.insert refId deps

  -- Load all terms
  terms <- loadTerms codeLookup allRefs

  -- Check that the main term was loaded
  case ref of
    Reference.Builtin _ -> pure $ Right terms
    Reference.DerivedId _ ->
      if Map.member ref terms
        then pure $ Right terms
        else pure $ Left (DependencyMissing ref)

-- -----------------------------------------------------------------------------
-- Phase 3: Multi-Term Compilation
-- -----------------------------------------------------------------------------

-- | Convert a Term to a SuperGroup with a custom DataSpec.
-- The DataSpec tells us constructor arities for saturation and pattern compilation.
-- The funcName is used for error messages in incomplete pattern matches.
termToSuperGroupWithDataSpec ::
  DataSpec ->
  Text ->
  Term Symbol Ann ->
  (SuperGroup Reference Symbol, [(Reference, SuperGroup Reference Symbol)])
termToSuperGroupWithDataSpec dataSpec funcName term =
  let -- Phase 1: Normalize the term (before lambda lifting)
      -- Uses the runtime's pipeline: inlineAlias → saturate → lamLift
      normalized =
        inlineAlias
          . Term.unannotate
          $ term

      -- Phase 2: Saturate constructors (requires DataSpec for arities)
      saturated = saturate (uncurryDspec dataSpec) normalized

      -- Phase 3: Lambda lift
      (mainTerm, _remap, _floatNames, ctx, _decompile) = lamLift mempty saturated

      -- Phase 4: Pattern compilation + default cases + ANF
      finalize =
        superNormalize
          . splitPatterns dataSpec
          . addDefaultCases funcName
   in (finalize mainTerm, fmap finalize <$> ctx)

-- | Compile multiple terms into a single WASM module.
-- The entry point is exported, dependencies become internal functions.
compileTermsToWasm ::
  Map Reference (Term Symbol Ann) ->
  Reference ->
  Text ->
  Either CodebaseError WatModule
compileTermsToWasm terms entryRef exportName = do
  -- Get the entry point term
  entryTerm <- case Map.lookup entryRef terms of
    Just t -> Right t
    Nothing -> Left (DependencyMissing entryRef)

  -- Convert entry point to SuperGroup (use exportName for nicer error messages)
  let (mainGroup, entryLiftedCtx) =
        termToSuperGroupWithDataSpec builtinDataSpec exportName entryTerm

  -- Convert all other loaded terms (dependencies) into top-level supergroups,
  -- and include any lambda-lifted supergroups they produce as well.
  --
  -- IMPORTANT: Cross-term calls in ANF are represented via References, so we must
  -- include dependency groups in the "lifted groups" table passed to
  -- compileGroupWithLifted; otherwise compilation fails with
  -- "No table index for reference in TName".
  let depTerms = Map.delete entryRef terms

      toGroups ::
        (Reference, Term Symbol Ann) ->
        ((Reference, SuperGroup Reference Symbol), [(Reference, SuperGroup Reference Symbol)])
      toGroups (ref, tm) =
        let (sg, lifted) =
              termToSuperGroupWithDataSpec builtinDataSpec (Text.pack (show ref)) tm
         in ((ref, sg), lifted)

      (depTopGroups, depLiftedGroups) =
        unzip (map toGroups (Map.toList depTerms))

      -- Combine:
      -- - every dependency's own top-level group (keyed by its reference)
      -- - all lambda-lifted groups from dependency compilation
      -- - all lambda-lifted groups from the entry compilation
      --
      -- Deduplicate by Reference and keep deterministic ordering.
      allLiftedRaw =
        depTopGroups ++ concat depLiftedGroups ++ entryLiftedCtx

      -- Keep the first occurrence for stability (later duplicates are ignored).
      allLiftedMap =
        foldl'
          (\m (r, g) -> if Map.member r m then m else Map.insert r g m)
          Map.empty
          allLiftedRaw

      allLifted =
        sortOn (show . fst) (Map.toList allLiftedMap)

  case compileGroupWithLifted mainGroup allLifted (Text.unpack exportName) of
    Left err -> Left (CompilationFailed err)
    Right wasm -> Right wasm

-- -----------------------------------------------------------------------------
-- Main Entry Points
-- -----------------------------------------------------------------------------

-- | Compile a term from a codebase by name or reference.
--
-- This function:
-- 1. Resolves the target to a Reference
-- 2. Loads the term and all its dependencies
-- 3. Compiles everything to a single WASM module
compileFromCodebase ::
  Codebase IO Symbol Ann ->
  Names ->
  CompileTarget ->
  Text ->
  IO (Either CodebaseError WatModule)
compileFromCodebase codebase names target exportName = do
  case resolveTarget names target of
    Left err -> pure $ Left err
    Right ref -> do
      let codeLookup = codebaseToCodeLookup codebase
      termsResult <- loadTermsWithDependencies codeLookup ref
      case termsResult of
        Left err -> pure $ Left err
        Right terms -> pure $ compileTermsToWasm terms ref exportName

-- | Compile a term directly from a TypecheckedUnisonFile (without codebase lookup).
-- This is useful for testing.
compileFromTypecheckedFile ::
  TypecheckedUnisonFile Symbol Ann ->
  Text ->
  Text ->
  Either CodebaseError WatModule
compileFromTypecheckedFile uf termName exportName = do
  -- Get names from the typechecked file
  let names = UF.typecheckedToNames uf

  -- Resolve the term name
  ref <- resolveName names termName

  -- Build a map of all terms in the file
  let allTerms = Map.fromList
        [ (Reference.DerivedId refId, tm)
        | (_sym, refId, _wk, tm, _typ) <- toList $ UF.hashTermsId uf
        ]

  -- Compile
  compileTermsToWasm allTerms ref exportName

-- -----------------------------------------------------------------------------
-- Codebase Path Entry Point
-- -----------------------------------------------------------------------------

-- | Load Names from a project/branch in a codebase.
--
-- This is the key operation for compiling terms by name from a real codebase.
loadProjectBranchNames ::
  Codebase IO Symbol Ann ->
  Text ->  -- ^ Project name (e.g., "@myuser/myproject" or just "myproject")
  Text ->  -- ^ Branch name (e.g., "main")
  IO (Either CodebaseError Names)
loadProjectBranchNames codebase projectName branchName = runExceptT $ do
  -- Parse project name
  let projName = UnsafeProjectName projectName

  -- Load project and branch from the database
  (project, branch) <- ExceptT $ Codebase.runTransactionWithRollback codebase $ \rollback -> do
    project <-
      Q.loadProjectByName projName
        `whenNothingM` rollback (Left $ ProjectNotFound projectName)
    branch <-
      Q.loadProjectBranchByName project.projectId (UnsafeProjectBranchName branchName)
        `whenNothingM` rollback (Left $ BranchNotFound projectName branchName)
    pure $ Right (project, branch)

  -- Load the branch root and convert to Names
  branchRoot <- liftIO $ Codebase.expectProjectBranchRoot codebase project.projectId branch.branchId
  pure $ Branch.toNames (Branch.head branchRoot)

-- | Compile a term from a codebase on disk, looking it up by name in a project/branch.
--
-- This is the "full stack" entry point for codebase-aware compilation:
--
-- @
-- result <- compileFromCodebasePath
--   "~/.unison"
--   "@myproject"
--   "main"
--   "myModule.calculateTotal"
--   "calculateTotal"
-- case result of
--   Right wasm -> writeFile "output.wat" (emitModule wasm)
--   Left err -> die (show err)
-- @
compileFromCodebasePath ::
  FilePath ->  -- ^ Path to .unison codebase directory
  Text ->      -- ^ Project name
  Text ->      -- ^ Branch name
  Text ->      -- ^ Term name to compile
  Text ->      -- ^ Export name in WASM module
  IO (Either CodebaseError WatModule)
compileFromCodebasePath codebasePath projectName branchName termName exportName = do
  -- Open codebase using SqliteCodebase.init
  let cbInit :: Init IO Symbol Ann
      cbInit = SC.init
  result <- (withOpenCodebase cbInit)
    "unison-wasm"
    codebasePath
    DontLock
    DontMigrate
    $ \codebase -> do
      -- Load Names from the project/branch
      namesResult <- loadProjectBranchNames codebase projectName branchName
      case namesResult of
        Left err -> pure $ Left err
        Right names -> do
          -- Compile the term
          compileFromCodebase codebase names (ByName termName) exportName

  -- Handle codebase open errors
  case result of
    Left openErr ->
      pure $ Left $ CodebaseOpenError codebasePath (Text.pack $ show openErr)
    Right compileResult ->
      pure compileResult

-- | Compile multiple terms from a codebase into a single WASM module.
--
-- Each term becomes an exported function.
-- All terms share dependencies (they're deduplicated).
--
-- @
-- result <- compileMultipleFromCodebasePath
--   ".unison"
--   "myproject"
--   "main"
--   [("calculatePrice", "calculatePrice"), ("calculateSubtotal", "calculateSubtotal")]
-- @
compileMultipleFromCodebasePath ::
  FilePath ->                -- ^ Path to .unison codebase directory
  Text ->                    -- ^ Project name
  Text ->                    -- ^ Branch name
  [(Text, Text)] ->          -- ^ List of (termName, exportName) pairs
  IO (Either CodebaseError WatModule)
compileMultipleFromCodebasePath codebasePath projectName branchName termPairs = do
  let cbInit :: Init IO Symbol Ann
      cbInit = SC.init
  result <- (withOpenCodebase cbInit)
    "unison-wasm"
    codebasePath
    DontLock
    DontMigrate
    $ \codebase -> do
      -- Load Names from the project/branch
      namesResult <- loadProjectBranchNames codebase projectName branchName
      case namesResult of
        Left err -> pure $ Left err
        Right names -> do
          let codeLookup = codebaseToCodeLookup codebase

          -- Resolve all term names to references
          let resolveAll = runExceptT $ forM termPairs $ \(termName, exportName) -> do
                ref <- ExceptT $ pure $ resolveTarget names (ByName termName)
                pure (ref, exportName)

          resolvedResult <- resolveAll
          case resolvedResult of
            Left err -> pure $ Left err
            Right resolved -> do
              -- Load all terms with their dependencies
              allTermsMaps <- forM resolved $ \(ref, _) ->
                loadTermsWithDependencies codeLookup ref

              case sequence allTermsMaps of
                Left err -> pure $ Left err
                Right termsMaps -> do
                  -- Merge all term maps
                  let mergedTerms = Map.unions termsMaps
                      entries = [(ref, exportName) | (ref, exportName) <- resolved]

                  -- Compile all entries together
                  pure $ compileMultipleTermsToWasm mergedTerms entries

  case result of
    Left openErr ->
      pure $ Left $ CodebaseOpenError codebasePath (Text.pack $ show openErr)
    Right compileResult ->
      pure compileResult

-- | Compile multiple entry points into a single WASM module.
compileMultipleTermsToWasm ::
  Map Reference (Term Symbol Ann) ->
  [(Reference, Text)] ->  -- ^ List of (reference, exportName) pairs
  Either CodebaseError WatModule
compileMultipleTermsToWasm terms entries = do
  -- Convert each entry to a SuperGroup, keeping the reference
  entrySuperGroups <- forM entries $ \(ref, exportName) -> do
    term <- case Map.lookup ref terms of
      Just t -> Right t
      Nothing -> Left (DependencyMissing ref)
    let (mainGroup, liftedCtx) =
          termToSuperGroupWithDataSpec builtinDataSpec exportName term
    pure (ref, mainGroup, Text.unpack exportName, liftedCtx)

  -- Collect all lifted groups from all entries
  let allLiftedRaw = concatMap (\(_, _, _, lifted) -> lifted) entrySuperGroups

  -- Also include other terms as potential dependencies
  let entryRefs = Set.fromList (map fst entries)
      depTerms = Map.filterWithKey (\r _ -> not (Set.member r entryRefs)) terms

      toGroups (ref, tm) =
        let (sg, lifted) = termToSuperGroupWithDataSpec builtinDataSpec (Text.pack (show ref)) tm
         in ((ref, sg), lifted)

      (depTopGroups, depLiftedGroups) = unzip (map toGroups (Map.toList depTerms))

      -- Combine all lifted groups
      allLiftedCombined = depTopGroups ++ concat depLiftedGroups ++ allLiftedRaw

      -- Deduplicate
      allLiftedMap =
        foldl'
          (\m (r, g) -> if Map.member r m then m else Map.insert r g m)
          Map.empty
          allLiftedCombined

      allLifted = sortOn (show . fst) (Map.toList allLiftedMap)

  -- Compile all entries together (now includes reference for cross-entry calls)
  let entryPairs = [(ref, sg, name) | (ref, sg, name, _) <- entrySuperGroups]

  case compileMultipleWithLifted entryPairs allLifted of
    Left err -> Left (CompilationFailed err)
    Right wasm -> Right wasm

