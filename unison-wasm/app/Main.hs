-- | CLI for WASM compilation from Unison source.
--
-- This executable compiles Unison code to WAT (WebAssembly Text format).
--
-- Usage:
--   unison-wasm-poc compile <name> <code> -- Compile Unison code to WAT
--   unison-wasm-poc debug <code>          -- Show parsed SuperGroup structure
module Main where

import Data.Functor.Identity (Identity, runIdentity)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Unison.Builtin qualified as B
import Unison.Parser.Ann (Ann)
import Unison.Reference (Reference)
import Unison.Runtime.ANF
  ( SuperGroup,
    lamLift,
    superNormalize,
  )
import Unison.Runtime.Pattern (splitPatterns, builtinDataSpec)
import Unison.Symbol (Symbol)
import Unison.Syntax.Parser qualified as Parser
import Unison.Syntax.TermParser qualified as TermParser
import Unison.Term qualified as Unison.Term
import Unison.Term (unannotate)
import Unison.Wasm.Compile (compileGroupWithLifted)
import Unison.Wasm.Emit (emitModule)

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
      -- Parse actual Unison code and compile to WAT
      -- Uses the full pipeline: parse → lamLift → superNormalize → compile
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
    [] -> usage
    _ -> do
      hPutStrLn stderr $ "Unknown command: " ++ unwords args
      usage
      exitFailure

usage :: IO ()
usage = do
  hPutStrLn stderr "Usage: unison-wasm-poc <command>"
  hPutStrLn stderr ""
  hPutStrLn stderr "Commands:"
  hPutStrLn stderr "  compile <name> <code>  Compile Unison code to WAT"
  hPutStrLn stderr "  debug <code>           Show parsed SuperGroup structure"
  hPutStrLn stderr ""
  hPutStrLn stderr "Examples:"
  hPutStrLn stderr "  unison-wasm-poc compile increment '##Nat.+ p0 1'"
  hPutStrLn stderr "  unison-wasm-poc compile add '##Nat.+ p0 p1'"
  hPutStrLn stderr "  unison-wasm-poc compile factorial \\"
  hPutStrLn stderr "    'let go n = match n with 0 -> 1; _ -> ##Nat.* n (go (##Nat.sub n 1)); go 5'"
