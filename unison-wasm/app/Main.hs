-- | CLI for WASM compilation from Unison source.
--
-- This executable compiles Unison code to WAT (WebAssembly Text format).
--
-- Usage:
--   unison-wasm-poc compile <name> <code>        -- Compile inline Unison code to WAT
--   unison-wasm-poc compile-codebase --codebase <path> --project <proj> --branch <branch> <term>
--                                                -- Compile from a .unison codebase
--   unison-wasm-poc types <name>                 -- Generate TypeScript definitions
--   unison-wasm-poc debug <code>                 -- Show parsed SuperGroup structure
module Main where

import Data.Text qualified as Text
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Unison.Builtin qualified as B
import Unison.Parser.Ann (Ann)
import Unison.Prelude
import Unison.Reference (Reference)
import Unison.Runtime.ANF
  ( SuperGroup,
    lamLift,
    superNormalize,
  )
import Unison.Runtime.Pattern (builtinDataSpec, splitPatterns)
import Unison.Symbol (Symbol)
import Unison.Syntax.Parser qualified as Parser
import Unison.Syntax.TermParser qualified as TermParser
import Unison.Term (unannotate)
import Unison.Term qualified as Unison.Term
import Unison.Wasm.Codebase (compileFromCodebasePath, compileMultipleFromCodebasePath)
import Unison.Wasm.Compile (compileGroupWithLifted)
import Unison.Wasm.Emit (emitModule)
import Unison.Wasm.TypeScript (TsType (..), generateDtsFromExports, generateModuleAugmentation)

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

-- | Parse a Unison expression string into a Term
parseTerm :: String -> Either String (Unison.Term.Term Symbol Ann)
parseTerm s =
  case runIdentity $ Parser.run (Parser.root TermParser.term) s parsingEnv of
    Left err -> Left (show err)
    Right tm -> Right tm

-- | Convert a parsed Term to a SuperGroup for compilation
-- Returns (main SuperGroup, [(ref, lifted combinator SuperGroups)])
termToSuperGroup :: Unison.Term.Term Symbol Ann -> (SuperGroup Reference Symbol, [(Reference, SuperGroup Reference Symbol)])
termToSuperGroup term =
  let (mainTerm, _, _, ctx, _) =
        lamLift mempty
          . splitPatterns builtinDataSpec
          . unannotate
          $ term
  in (superNormalize mainTerm, fmap superNormalize <$> ctx)

-- | Parse Unison code and compile to SuperGroup
parseAndCompile :: String -> Either String (SuperGroup Reference Symbol, [(Reference, SuperGroup Reference Symbol)])
parseAndCompile code = do
  term <- parseTerm code
  pure $ termToSuperGroup term

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["debug", code] -> do
      -- Debug: Show the parsed SuperGroup structure
      case parseAndCompile code of
        Left parseErr -> do
          hPutStrLn stderr $ "Parse error: " ++ parseErr
          exitFailure
        Right (sg, ctx) -> do
          putStrLn "=== Main SuperGroup ==="
          print sg
          putStrLn "\n=== Lifted Combinators ==="
          mapM_ (\(ref, lsg) -> putStrLn (show ref) >> print lsg >> putStrLn "") ctx
    ["compile", name, code] -> do
      -- Parse inline Unison code and compile to WAT
      -- Uses the full pipeline: parse → lamLift → superNormalize → compile
      compileCode name code
    -- compile-codebase: Full codebase integration
    -- Usage: compile-codebase --codebase <path> --project <proj> --branch <branch> <term> [term2 ...]
    ("compile-codebase" : rest) -> do
      case parseCodebaseArgs rest of
        Left err -> do
          hPutStrLn stderr $ "Error: " ++ err
          hPutStrLn stderr ""
          hPutStrLn stderr "Usage: compile-codebase --codebase <path> --project <proj> --branch <branch> <term> [term2 ...]"
          exitFailure
        Right (cbPath, projName, branchName, termNames) ->
          case termNames of
            [termName] -> do
              -- Single term: use existing function
              result <- compileFromCodebasePath
                cbPath
                (Text.pack projName)
                (Text.pack branchName)
                (Text.pack termName)
                (Text.pack termName)  -- export name = term name
              case result of
                Left err -> do
                  hPutStrLn stderr $ "Compilation error: " ++ show err
                  exitFailure
                Right wasm -> putStr (emitModule wasm)
            _ -> do
              -- Multiple terms: use multi-entry function
              let termPairs = [(Text.pack t, Text.pack t) | t <- termNames]
              result <- compileMultipleFromCodebasePath
                cbPath
                (Text.pack projName)
                (Text.pack branchName)
                termPairs
              case result of
                Left err -> do
                  hPutStrLn stderr $ "Compilation error: " ++ show err
                  exitFailure
                Right wasm -> putStr (emitModule wasm)
    ["types", name] -> do
      -- Generate TypeScript type definitions for a compiled module
      let dts = generateDtsFromExports name
            [ (name, [TsBigInt], TsBigInt)  -- Default: assumes Nat -> Nat
            ]
      putStr dts
    ["types", name, argType, retType] -> do
      -- Generate TypeScript definitions with explicit types
      let argTs = parseTypeArg argType
          retTs = parseTypeArg retType
          dts = generateDtsFromExports name [(name, [argTs], retTs)]
      putStr dts
    -- generate-types: Generate module augmentation for type-safe runtime.run()
    -- Usage: generate-types <name>:<arg1>,<arg2>,...-><ret> [more functions...]
    -- Example: generate-types "calculatePrice:bigint,bigint->[bigint,bigint,bigint]"
    ("generate-types" : specs) -> do
      case traverse parseFunctionSpec specs of
        Left err -> do
          hPutStrLn stderr $ "Error parsing function spec: " ++ err
          exitFailure
        Right parsed -> do
          putStr $ generateModuleAugmentation parsed
    [] -> usage
    _ -> do
      hPutStrLn stderr $ "Unknown command: " ++ unwords args
      usage
      exitFailure

-- | Compile Unison code string to WAT and print it
compileCode :: String -> String -> IO ()
compileCode name code =
  case parseAndCompile code of
    Left parseErr -> do
      hPutStrLn stderr $ "Parse error: " ++ parseErr
      exitFailure
    Right (sg, liftedCtx) -> do
      -- Compile main group + lifted combinators
      case compileGroupWithLifted sg liftedCtx name of
        Left compileErr -> do
          hPutStrLn stderr $ "Compilation error: " ++ show compileErr
          exitFailure
        Right wasm -> putStr (emitModule wasm)

-- | Parse a type argument string to TsType
parseTypeArg :: String -> TsType
parseTypeArg "Nat" = TsBigInt
parseTypeArg "Int" = TsBigInt
parseTypeArg "Float" = TsNumber
parseTypeArg "Text" = TsString
parseTypeArg "Boolean" = TsBoolean
parseTypeArg "Unit" = TsVoid
parseTypeArg "bigint" = TsBigInt  -- Allow TypeScript type names
parseTypeArg "number" = TsNumber
parseTypeArg "string" = TsString
parseTypeArg "boolean" = TsBoolean
parseTypeArg "void" = TsVoid
parseTypeArg name
  | "[" `isPrefixOf` name && "]" `isSuffixOf` name =
      -- Tuple type like [bigint,bigint,bigint]
      let inner = drop 1 (take (length name - 1) name)
          parts = splitOn ',' inner
      in TsTuple (map parseTypeArg parts)
  | otherwise = TsNamed name
  where
    isPrefixOf prefix str = take (length prefix) str == prefix
    isSuffixOf suffix str = drop (length str - length suffix) str == suffix
    splitOn _ [] = []
    splitOn c s = case break (== c) s of
      (x, []) -> [x]
      (x, _ : rest) -> x : splitOn c rest

-- | Parse a function spec like "funcName:arg1,arg2->ret"
parseFunctionSpec :: String -> Either String (String, [TsType], TsType)
parseFunctionSpec spec =
  case break (== ':') spec of
    (_, []) -> Left $ "Missing ':' in spec: " ++ spec
    (name, ':' : rest) ->
      case break (== '-') rest of
        (_, []) -> Left $ "Missing '->' in spec: " ++ spec
        (argsPart, '-' : '>' : retPart) ->
          let args = if null argsPart then [] else map parseTypeArg (splitOn ',' argsPart)
              ret = parseTypeArg retPart
          in Right (name, args, ret)
        _ -> Left $ "Invalid '->' in spec: " ++ spec
    _ -> Left $ "Invalid spec: " ++ spec
  where
    splitOn _ [] = []
    splitOn c s = case break (== c) s of
      (x, []) -> [x]
      (x, _ : rest) -> x : splitOn c rest

-- | Parse compile-codebase command arguments
-- Returns: (codebasePath, projectName, branchName, termNames)
parseCodebaseArgs :: [String] -> Either String (FilePath, String, String, [String])
parseCodebaseArgs args = go Nothing Nothing Nothing args
  where
    go :: Maybe FilePath -> Maybe String -> Maybe String -> [String] -> Either String (FilePath, String, String, [String])
    go _mcb mproj mbranch ("--codebase" : path : rest) = go (Just path) mproj mbranch rest
    go mcb _mproj mbranch ("--project" : proj : rest) = go mcb (Just proj) mbranch rest
    go mcb mproj _mbranch ("--branch" : branch : rest) = go mcb mproj (Just branch) rest
    go (Just cb) (Just proj) (Just branch) terms | not (null terms) =
      Right (cb, proj, branch, terms)
    go Nothing _ _ _ = Left "Missing --codebase <path>"
    go _ Nothing _ _ = Left "Missing --project <name>"
    go _ _ Nothing _ = Left "Missing --branch <name>"
    go _ _ _ [] = Left "Missing term name(s)"
    go _ _ _ _ = Left "Unrecognized option"

usage :: IO ()
usage = do
  hPutStrLn stderr "Usage: unison-wasm-poc <command>"
  hPutStrLn stderr ""
  hPutStrLn stderr "Commands:"
  hPutStrLn stderr "  compile <name> <code>               Compile inline Unison code to WAT"
  hPutStrLn stderr "  compile-codebase --codebase <path> --project <proj> --branch <branch> <term> [term2 ...]"
  hPutStrLn stderr "                                      Compile term(s) from a .unison codebase"
  hPutStrLn stderr "  types <name>                        Generate TypeScript .d.ts (default: Nat -> Nat)"
  hPutStrLn stderr "  types <name> <arg> <ret>            Generate .d.ts with explicit types"
  hPutStrLn stderr "  generate-types <spec> [spec ...]    Generate module augmentation for runtime.run()"
  hPutStrLn stderr "  debug <code>                        Show parsed SuperGroup structure"
  hPutStrLn stderr ""
  hPutStrLn stderr "Types: Nat, Int, Float, Text, Boolean, Unit, bigint, number, string, [type,type,...]"
  hPutStrLn stderr ""
  hPutStrLn stderr "Examples:"
  hPutStrLn stderr "  unison-wasm-poc compile increment 'x -> ##Nat.+ x 1'"
  hPutStrLn stderr "  unison-wasm-poc compile-codebase --codebase .unison --project demo --branch main calculateSubtotal"
  hPutStrLn stderr "  unison-wasm-poc types factorial"
  hPutStrLn stderr "  unison-wasm-poc types greet Text Text"
  hPutStrLn stderr "  unison-wasm-poc generate-types 'calculatePrice:bigint,bigint->[bigint,bigint,bigint]'"
