-- | Fixture-based tests: Read .u files, run through BOTH native runtime and WASM,
-- compare results. No hardcoded expected values.
module Unison.Test.Wasm.Fixtures where

import Data.Functor.Identity (Identity, runIdentity)
import Data.List (intercalate, isSuffixOf)
import Data.Word (Word64)
import EasyTest
import System.Directory (listDirectory, doesDirectoryExist)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>), takeBaseName, takeDirectory)
import System.IO (hClose, hPutStr)
import System.IO.Temp (withSystemTempFile)
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)
import Unison.ABT qualified as ABT
import Unison.Builtin qualified as B
import Unison.Codebase.CodeLookup qualified as CL
import Unison.Codebase.Runtime qualified as Rt
import Unison.Codebase.Runtime.Profile (ProfileSpec (..))
import Unison.Parser.Ann (Ann)
import Unison.PrettyPrintEnv qualified as PPE
import Unison.Runtime.ANF (lamLift, superNormalize)
import Unison.Runtime.Interface (RuntimeHost (..), startRuntime)
import Unison.Runtime.Pattern (builtinDataSpec, splitPatterns)
import Unison.Symbol (Symbol)
import Unison.Syntax.Parser qualified as Parser
import Unison.Syntax.TermParser qualified as TermParser
import Unison.Term (unannotate)
import Unison.Term qualified as Term
import Unison.Wasm.Compile (compileGroupWithLifted)
import Unison.Wasm.Emit (emitModule)

--------------------------------------------------------------------------------
-- Main Test Entry Point
--------------------------------------------------------------------------------

test :: Test ()
test = scope "fixtures" $ do
  -- Discover all .u files under tests/fixtures/
  fixtures <- io $ discoverFixtures "tests/fixtures"
  if null fixtures
    then do
      note "No .u fixtures found in tests/fixtures/"
      crash "No fixtures"
    else tests $ map testOneFixture fixtures

--------------------------------------------------------------------------------
-- Fixture Discovery
--------------------------------------------------------------------------------

-- | Recursively find all .u files under a directory
discoverFixtures :: FilePath -> IO [FilePath]
discoverFixtures dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      entries <- listDirectory dir
      paths <- concat <$> mapM (processEntry dir) entries
      pure paths
  where
    processEntry parent name = do
      let path = parent </> name
      isDir <- doesDirectoryExist path
      if isDir
        then discoverFixtures path
        else pure [path | ".u" `isSuffixOf` name]

--------------------------------------------------------------------------------
-- Parsing
--------------------------------------------------------------------------------

parsingEnv :: Parser.ParsingEnv Identity
parsingEnv =
  Parser.ParsingEnv
    { uniqueNames = mempty,
      uniqueTypeGuid = \_ -> pure Nothing,
      names = B.names,
      maybeNamespace = Nothing,
      localNamespacePrefixedTypesAndConstructors = mempty
    }

parseTerm :: String -> Either String (Term.Term Symbol Ann)
parseTerm s =
  case runIdentity $ Parser.run (Parser.root TermParser.term) s parsingEnv of
    Left err -> Left (show err)
    Right tm -> Right tm

-- | Filter out comments and empty lines
cleanCode :: String -> String
cleanCode content = intercalate "\n" $ filter (not . isComment) $ lines content
  where
    isComment s = case dropWhile (== ' ') s of
      ('-':'-':_) -> True
      [] -> True
      _ -> False

--------------------------------------------------------------------------------
-- Native Runtime Evaluation
--------------------------------------------------------------------------------

-- | Run a term through the native Unison runtime, return the numeric result.
--
-- LIMITATION: Currently only supports numeric results (Nat, Int, Float)
-- because WASM returns i64 from wasmtime. Future: support richer comparison.
runNative :: Term.Term Symbol Ann -> IO (Either String Word64)
runNative term = do
  runtime <- startRuntime False OneOff "test"
  let cl = mempty :: CL.CodeLookup Symbol IO ()
      ppe = PPE.empty
  result <- Rt.evaluate runtime cl ppe NoProf (Term.amap (const ()) term)
  Rt.terminate runtime
  pure $ case result of
    Left _err -> Left "Native runtime error"
    Right (_, resultTerm) -> extractNumeric resultTerm

-- | Extract a numeric value from a Term.
--
-- Supports: Nat, Int, Float (truncated to i64)
-- Does NOT support: Text, Data, Lists, etc.
extractNumeric :: Term.Term Symbol () -> Either String Word64
extractNumeric tm = case ABT.out tm of
  ABT.Tm (Term.Nat n) -> Right n
  ABT.Tm (Term.Int n) -> Right (fromIntegral n)
  ABT.Tm (Term.Float f) -> Right (round f)  -- Truncate float to int for comparison
  _ -> Left $ "Result is not numeric (Nat/Int/Float): " ++ take 100 (show tm)

--------------------------------------------------------------------------------
-- WASM Compilation and Execution
--------------------------------------------------------------------------------

compileToWat :: String -> Term.Term Symbol Ann -> Either String String
compileToWat name term = do
  let (mainTerm, _, _, ctx, _) =
        lamLift mempty . splitPatterns builtinDataSpec . unannotate $ term
      sg = superNormalize mainTerm
      liftedCtx = fmap superNormalize <$> ctx
  case compileGroupWithLifted sg liftedCtx name of
    Left err -> Left (show err)
    Right wasm -> Right (emitModule wasm)

getWasmtimePath :: IO FilePath
getWasmtimePath = do
  mPath <- lookupEnv "WASMTIME_PATH"
  pure $ case mPath of
    Just p -> p
    Nothing -> "/home/vscode/.wasmtime/bin/wasmtime"

runWasm :: String -> String -> IO (Either String Word64)
runWasm funcName watSource = do
  wasmtimePath <- getWasmtimePath
  withSystemTempFile "test.wat" $ \path handle -> do
    hPutStr handle watSource
    hClose handle
    (exitCode, stdout, stderr) <- readProcessWithExitCode
      wasmtimePath
      ["run", "--invoke", funcName, path]
      ""
    case exitCode of
      ExitSuccess ->
        case readMaybe (trim stdout) of
          Just n -> pure $ Right n
          Nothing -> pure $ Left $ "Parse WASM output error: " ++ show stdout
      ExitFailure _ ->
        pure $ Left $ "wasmtime error: " ++ stderr
  where
    trim = dropWhile (== ' ') . reverse . dropWhile (== ' ') . reverse . filter (/= '\n')

--------------------------------------------------------------------------------
-- Test Runner
--------------------------------------------------------------------------------

-- | Test a single .u fixture: run through native AND WASM, compare results
testOneFixture :: FilePath -> Test ()
testOneFixture path = scope testName $ do
  content <- io $ readFile path
  let code = cleanCode content
      name = takeBaseName path

  -- Parse
  case parseTerm code of
    Left err -> do
      note $ "Parse error in " ++ path ++ ": " ++ err
      crash "Parse failed"
    Right term -> do
      -- Run native
      nativeResult <- io $ runNative term
      case nativeResult of
        Left err -> do
          note $ "Native runtime error: " ++ err
          crash "Native failed"
        Right nativeVal -> do
          -- Compile to WASM
          case compileToWat name term of
            Left err -> do
              note $ "WASM compile error: " ++ err
              crash "WASM compile failed"
            Right wat -> do
              -- Run WASM
              wasmResult <- io $ runWasm name wat
              case wasmResult of
                Left err -> do
                  note $ "WASM runtime error: " ++ err
                  crash "WASM failed"
                Right wasmVal -> do
                  -- Compare!
                  if nativeVal == wasmVal
                    then do
                      note $ "✓ Native=" ++ show nativeVal ++ " WASM=" ++ show wasmVal
                      ok
                    else do
                      note $ "MISMATCH: Native=" ++ show nativeVal ++ " WASM=" ++ show wasmVal
                      crash "Results differ"
  where
    -- Create a readable test name from the path
    testName =
      let dir = takeBaseName (takeDirectory path)
          base = takeBaseName path
      in dir ++ "." ++ base
