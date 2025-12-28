-- | Phase 1-2 CLI for WASM emission.
--
-- This executable emits WAT for testing the emission and compilation pipelines.
--
-- Usage:
--   unison-wasm-poc emit-increment    -- Emit the hardcoded increment function as WAT
--   unison-wasm-poc emit-add          -- Emit a compiled add function as WAT (Phase 2)
--   unison-wasm-poc emit-factorial    -- Emit a factorial function as WAT (Phase 2)
--   unison-wasm-poc compile <name> <code> -- Compile Unison code to WAT
module Main where

import Data.Functor.Identity (Identity, runIdentity)
import Data.Text qualified as Text
import Data.Word (Word64)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Unison.Builtin qualified as B
import Unison.Parser.Ann (Ann)
import Unison.Reference (Reference)
import Unison.Reference qualified as Reference
import Unison.ABT.Normalized qualified as ABTN
import Unison.Runtime.ANF
  ( ANormal,
    Branched (..),
    Direction (..),
    Func (..),
    Lit (..),
    Mem (..),
    SuperGroup (..),
    SuperNormal (..),
    lamLift,
    superNormalize,
    pattern TApp,
    pattern TLets,
    pattern TLit,
    pattern TMatch,
    pattern TPrm,
    pattern TVar,
  )
import Unison.Runtime.ANF.POp (POp (..))
import Unison.Runtime.Pattern (splitPatterns, builtinDataSpec)
import Unison.Symbol (Symbol)
import Unison.Syntax.Parser qualified as Parser
import Unison.Syntax.TermParser qualified as TermParser
import Unison.Term qualified as Unison.Term
import Unison.Term (unannotate)
import Unison.Util.EnumContainers qualified as EC
import Unison.Var qualified as Var
import Unison.Wasm.Compile (compileGroup, compileGroupWithLifted)
import Unison.Wasm.Emit (emitModule, incrementModule)

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

-- | Helper to create a Symbol from a string
sym :: String -> Symbol
sym = Var.named . Text.pack

-- | Wrap a body in TAbs nodes for parameters (p0, p1, ...)
wrapAbs :: [Mem] -> Int -> ANormal Reference Symbol -> ANormal Reference Symbol
wrapAbs [] _ body = body
wrapAbs (_:rest) i body =
  ABTN.TAbs (sym $ "p" ++ show i) (wrapAbs rest (i + 1) body)

-- | Create a SuperNormal with proper TAbs wrapping for parameters
mkLambda :: [Mem] -> ANormal Reference Symbol -> SuperNormal Reference Symbol
mkLambda mems body = Lambda mems (wrapAbs mems 0 body)

-- | Create an add function SuperGroup: add(a, b) = a + b
--
-- This is the same as writing in Unison:
--   add : Nat -> Nat -> Nat
--   add a b = a + b
addSuperGroup :: SuperGroup Reference Symbol
addSuperGroup = Rec [] addLambda
  where
    addLambda :: SuperNormal Reference Symbol
    addLambda = mkLambda [UN, UN] addBody

    addBody = TPrm ADDN [sym "p0", sym "p1"]

-- | Create a multiply function SuperGroup: mul(a, b) = a * b
mulSuperGroup :: SuperGroup Reference Symbol
mulSuperGroup = Rec [] mulLambda
  where
    mulLambda = mkLambda [UN, UN] (TPrm MULN [sym "p0", sym "p1"])

-- | Create an identity function SuperGroup: identity(x) = x
identitySuperGroup :: SuperGroup Reference Symbol
identitySuperGroup = Rec [] identityLambda
  where
    identityLambda = mkLambda [UN] (TVar (sym "p0"))

-- | Create a factorial function SuperGroup: factorial(n) = if n == 0 then 1 else n * factorial(n - 1)
--
-- This is the same as writing in Unison:
--   factorial : Nat -> Nat
--   factorial n = if n == 0 then 1 else n * factorial (n - 1)
--
-- ANF representation (in pseudo-code):
--   factorial n =
--     match n with
--       0 -> 1
--       _ -> let one = 1
--            let n1 = n - one
--            let rec = factorial n1
--            n * rec
factorialSuperGroup :: SuperGroup Reference Symbol
factorialSuperGroup = Rec [] factorialLambda
  where
    factorialLambda :: SuperNormal Reference Symbol
    factorialLambda = mkLambda [UN] factorialBody

    -- Pattern match on n: if n == 0 then 1 else recursive case
    factorialBody :: ANormal Reference Symbol
    factorialBody = TMatch (sym "p0") matchCases

    -- MatchIntegral: case 0 -> 1, default -> recursive multiplication
    matchCases :: Branched Reference (ANormal Reference Symbol)
    matchCases = MatchIntegral
      (EC.mapFromList [(0 :: Word64, baseCase)])  -- Case: n == 0
      (Just recursiveCase)                         -- Default: n > 0

    -- Base case: return 1
    baseCase :: ANormal Reference Symbol
    baseCase = TLit (N 1)

    -- Recursive case: n * factorial(n - 1)
    -- In ANF, we need to bind constants first since TPrm only takes variables:
    --   let one = 1
    --   let n1 = n - one
    --   let rec = factorial n1
    --   n * rec
    recursiveCase :: ANormal Reference Symbol
    recursiveCase =
      -- First bind the constant 1
      TLets Direct [sym "one"] [UN]
        (TLit (N 1))
        -- Then compute n - 1
        (TLets Direct [sym "n1"] [UN]
          (TPrm SUBN [sym "p0", sym "one"])
          -- Then recursive call: use FComb with a placeholder reference
          -- The compiler ignores the reference and uses ctxCurrentFunc
          (TLets Direct [sym "rec"] [UN]
            (TApp (FComb selfRef) [sym "n1"])
            -- Finally multiply n * rec
            (TPrm MULN [sym "p0", sym "rec"])))

    -- A placeholder reference for self-recursion
    -- The reference is required by the strict FComb constructor but
    -- the compiler ignores it and uses ctxCurrentFunc instead
    selfRef :: Reference
    selfRef = Reference.Builtin "factorial"

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["emit-increment"] -> do
      -- Phase 1: Hardcoded increment
      putStr (emitModule incrementModule)
    ["emit-add"] -> do
      -- Phase 2: Compiled from SuperGroup
      case compileGroup addSuperGroup "add" of
        Left err -> do
          hPutStrLn stderr $ "Compilation error: " ++ show err
          exitFailure
        Right wasm -> putStr (emitModule wasm)
    ["emit-mul"] -> do
      -- Phase 2: Compiled from SuperGroup
      case compileGroup mulSuperGroup "mul" of
        Left err -> do
          hPutStrLn stderr $ "Compilation error: " ++ show err
          exitFailure
        Right wasm -> putStr (emitModule wasm)
    ["emit-identity"] -> do
      -- Phase 2: Compiled from SuperGroup
      case compileGroup identitySuperGroup "identity" of
        Left err -> do
          hPutStrLn stderr $ "Compilation error: " ++ show err
          exitFailure
        Right wasm -> putStr (emitModule wasm)
    ["emit-factorial"] -> do
      -- Phase 2: Factorial - the Phase 2 exit criteria
      case compileGroup factorialSuperGroup "factorial" of
        Left err -> do
          hPutStrLn stderr $ "Compilation error: " ++ show err
          exitFailure
        Right wasm -> putStr (emitModule wasm)
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
      -- Phase 2: Parse actual Unison code and compile to WAT
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
  hPutStrLn stderr "  emit-increment      Emit the increment function as WAT (Phase 1)"
  hPutStrLn stderr "  emit-add            Emit add(a, b) = a + b as WAT (Phase 2)"
  hPutStrLn stderr "  emit-mul            Emit mul(a, b) = a * b as WAT (Phase 2)"
  hPutStrLn stderr "  emit-identity       Emit identity(x) = x as WAT (Phase 2)"
  hPutStrLn stderr "  emit-factorial      Emit factorial(n) as WAT (Phase 2 exit criteria, hardcoded)"
  hPutStrLn stderr "  compile <name> <code> Compile Unison code to WAT (Phase 2)"
  hPutStrLn stderr ""
  hPutStrLn stderr "Examples:"
  hPutStrLn stderr "  unison-wasm-poc compile add '##Nat.+ p0 p1'"
  hPutStrLn stderr "  unison-wasm-poc compile fact 'let go n = match n with 0 -> 1; _ -> ##Nat.* n (go (##Nat.sub n 1)); go p0'"
