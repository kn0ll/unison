-- | End-to-end integration tests: Unison code → WAT → WASM execution → result verification
--
-- These tests use wasmtime to execute the compiled WASM and verify correctness.
module Unison.Test.Wasm.Integration where

import Data.Functor.Identity (Identity, runIdentity)
import EasyTest
import System.Exit (ExitCode (..))
import System.IO (hClose, hPutStr)
import System.IO.Temp (withSystemTempFile)
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)
import Unison.Builtin qualified as B
import Unison.Parser.Ann (Ann)
import Unison.Runtime.ANF (lamLift, superNormalize)
import Unison.Runtime.Pattern (builtinDataSpec, splitPatterns)
import Unison.Symbol (Symbol)
import Unison.Syntax.Parser qualified as Parser
import Unison.Syntax.TermParser qualified as TermParser
import Unison.Term (unannotate)
import Unison.Term qualified as Unison.Term
import Unison.Wasm.Compile (compileGroupWithLifted)
import Unison.Wasm.Emit (emitModule)

--------------------------------------------------------------------------------
-- WASM Execution via wasmtime
--------------------------------------------------------------------------------

-- | Result of executing WASM
data WasmResult
  = WasmI64 Integer
  | WasmF64 Double
  | WasmError String
  deriving (Eq, Show)

-- | Execute a WAT module and invoke a function, returning its i64 result.
--
-- Uses wasmtime CLI: wasmtime run --invoke <func> <file.wat>
executeWat :: String -> String -> IO WasmResult
executeWat funcName watSource = do
  withSystemTempFile "test.wat" $ \path handle -> do
    hPutStr handle watSource
    hClose handle
    
    -- wasmtime can run WAT directly
    (exitCode, stdout, stderr) <- readProcessWithExitCode
      wasmtimePath
      ["run", "--invoke", funcName, path]
      ""
    
    case exitCode of
      ExitSuccess ->
        -- wasmtime outputs the result as a number
        case parseWasmOutput (trim stdout) of
          Just val -> pure val
          Nothing -> pure $ WasmError $ "Failed to parse output: " ++ show stdout
      ExitFailure _ ->
        pure $ WasmError $ "wasmtime failed: " ++ stderr
  where
    wasmtimePath = "/home/vscode/.wasmtime/bin/wasmtime"
    trim = dropWhile (== ' ') . reverse . dropWhile (== ' ') . reverse . filter (/= '\n')

-- | Parse wasmtime output (e.g., "120" or "3.14")
parseWasmOutput :: String -> Maybe WasmResult
parseWasmOutput s
  | Just i <- readMaybe s = Just (WasmI64 i)
  | Just f <- readMaybe s = Just (WasmF64 f)
  | otherwise = Nothing

--------------------------------------------------------------------------------
-- Compilation Pipeline
--------------------------------------------------------------------------------

-- | Parsing environment with builtin names
parsingEnv :: Parser.ParsingEnv Identity
parsingEnv =
  Parser.ParsingEnv
    { uniqueNames = mempty,
      uniqueTypeGuid = \_ -> pure Nothing,
      names = B.names,
      maybeNamespace = Nothing,
      localNamespacePrefixedTypesAndConstructors = mempty
    }

-- | Full pipeline: Unison source → WAT text
compileToWat :: String -> String -> Either String String
compileToWat name code = do
  -- Parse
  term <- parseTerm code
  
  -- Lambda lift and normalize
  let (mainTerm, _, _, ctx, _) =
        lamLift mempty . splitPatterns builtinDataSpec . unannotate $ term
      sg = superNormalize mainTerm
      liftedCtx = fmap superNormalize <$> ctx
  
  -- Compile to WAT
  case compileGroupWithLifted sg liftedCtx name of
    Left err -> Left (show err)
    Right wasm -> Right (emitModule wasm)

-- | Parse Unison source to a Term
parseTerm :: String -> Either String (Unison.Term.Term Symbol Ann)
parseTerm s =
  case runIdentity $ Parser.run (Parser.root TermParser.term) s parsingEnv of
    Left err -> Left (show err)
    Right tm -> Right tm

--------------------------------------------------------------------------------
-- End-to-End Test Helper
--------------------------------------------------------------------------------

-- | Run a complete end-to-end test: Unison code → execute → verify result
--
-- Example:
--   testE2E "add" "##Nat.+ 3 4" (WasmI64 7)
testE2E :: String -> String -> WasmResult -> Test ()
testE2E name code expected = scope name $ do
  case compileToWat name code of
    Left err -> crash $ "Compilation failed: " ++ err
    Right wat -> do
      result <- io $ executeWat name wat
      case result of
        WasmError err -> crash $ "Execution failed: " ++ err
        actual -> expectEqual actual expected

--------------------------------------------------------------------------------
-- Integration Tests
--------------------------------------------------------------------------------

test :: Test ()
test =
  scope "integration" . tests $
    [ testArithmetic,
      testCompoundExpressions
    ]

-- | Test basic arithmetic operations
testArithmetic :: Test ()
testArithmetic =
  scope "arithmetic" . tests $
    [ -- ##Nat.+ 3 4 = 7
      testE2E "add_3_4" "##Nat.+ 3 4" (WasmI64 7),
      
      -- ##Nat.sub 10 3 = 7
      testE2E "sub_10_3" "##Nat.sub 10 3" (WasmI64 7),
      
      -- ##Nat.* 6 7 = 42
      testE2E "mul_6_7" "##Nat.* 6 7" (WasmI64 42),
      
      -- ##Nat./ 20 4 = 5
      testE2E "div_20_4" "##Nat./ 20 4" (WasmI64 5),
      
      -- ##Nat.mod 17 5 = 2
      testE2E "mod_17_5" "##Nat.mod 17 5" (WasmI64 2),
      
      -- Literal: 42
      testE2E "literal_42" "42" (WasmI64 42),
      
      -- Literal: 0
      testE2E "literal_0" "0" (WasmI64 0),
      
      -- Large number
      testE2E "large" "9999999999" (WasmI64 9999999999)
    ]

-- | Test compound expressions (nested operations)
testCompoundExpressions :: Test ()
testCompoundExpressions =
  scope "compound" . tests $
    [ -- (3 + 4) - 2 = 5
      testE2E "add_sub" "##Nat.sub (##Nat.+ 3 4) 2" (WasmI64 5),
      
      -- (5 * 6) + 7 = 37
      testE2E "mul_add" "##Nat.+ (##Nat.* 5 6) 7" (WasmI64 37),
      
      -- (10 - 3) * 2 = 14
      testE2E "sub_mul" "##Nat.* (##Nat.sub 10 3) 2" (WasmI64 14),
      
      -- ((2 + 3) * 4) - 5 = 15
      testE2E "nested" "##Nat.sub (##Nat.* (##Nat.+ 2 3) 4) 5" (WasmI64 15)
    ]

-- NOTE: The following features are not yet tested because they require
-- Phase 3 compiler improvements:
--
-- - let bindings: "let x = 42; x" (lamLift issue)
-- - pattern matching: Multi-branch MatchIntegral
-- - recursion: Requires pattern matching
-- - factorial: "let go n = match n with 0 -> 1; _ -> ##Nat.* n (go (##Nat.sub n 1)); go 5"
--
-- Once Phase 3 is complete, add tests like:
--   testE2E "factorial_5" "let go n = match n with 0 -> 1; _ -> ##Nat.* n (go (##Nat.sub n 1)); go 5" (WasmI64 120)

