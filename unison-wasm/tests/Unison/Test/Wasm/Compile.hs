-- | Tests for the SuperGroup → WAT compiler using real Unison parsing.
module Unison.Test.Wasm.Compile where

import Data.Functor.Identity (Identity, runIdentity)
import Data.List (isInfixOf)
import EasyTest
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
import Unison.Wasm.Emit (WatModule (..), emitModule)

--------------------------------------------------------------------------------
-- Test Helpers: Parse real Unison code
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

-- | Parse Unison source to a Term
parseTerm :: String -> Either String (Unison.Term.Term Symbol Ann)
parseTerm s =
  case runIdentity $ Parser.run (Parser.root TermParser.term) s parsingEnv of
    Left err -> Left (show err)
    Right tm -> Right tm

-- | Convert a parsed Term to SuperGroups
termToSuperGroups :: Unison.Term.Term Symbol Ann -> (SuperGroup Reference Symbol, [(Reference, SuperGroup Reference Symbol)])
termToSuperGroups term =
  let (mainTerm, _, _, ctx, _) =
        lamLift mempty
          . splitPatterns builtinDataSpec
          . unannotate
          $ term
  in (superNormalize mainTerm, fmap superNormalize <$> ctx)

-- | Parse and compile Unison source to WAT
compileUnison :: String -> String -> Either String WatModule
compileUnison name code = do
  term <- parseTerm code
  let (sg, liftedCtx) = termToSuperGroups term
  case compileGroupWithLifted sg liftedCtx name of
    Left err -> Left (show err)
    Right wasm -> Right wasm

-- | Parse and compile, returning WAT text
compileToWat :: String -> String -> Either String String
compileToWat name code = emitModule <$> compileUnison name code

--------------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------------

test :: Test ()
test =
  scope "compile" . tests $
    [ testLiterals,
      testArithmetic
    ]

--------------------------------------------------------------------------------
-- Literal Tests
--------------------------------------------------------------------------------

testLiterals :: Test ()
testLiterals =
  scope "literals" . tests $
    [ scope "nat_42" $ do
        case compileToWat "const42" "42" of
          Left err -> crash $ "Compilation failed: " ++ err
          Right wat -> do
            expect ("i64.const 42" `isInfixOf` wat),
      scope "nat_0" $ do
        case compileToWat "zero" "0" of
          Left err -> crash $ "Compilation failed: " ++ err
          Right wat -> do
            expect ("i64.const 0" `isInfixOf` wat),
      scope "large_nat" $ do
        case compileToWat "large" "9999999999" of
          Left err -> crash $ "Compilation failed: " ++ err
          Right wat -> do
            expect ("i64.const 9999999999" `isInfixOf` wat)
    ]

--------------------------------------------------------------------------------
-- Arithmetic Tests
--------------------------------------------------------------------------------

testArithmetic :: Test ()
testArithmetic =
  scope "arithmetic" . tests $
    [ scope "add" $ do
        case compileToWat "add" "##Nat.+ 3 4" of
          Left err -> crash $ "Compilation failed: " ++ err
          Right wat -> do
            expect ("i64.add" `isInfixOf` wat),
      scope "sub" $ do
        case compileToWat "sub" "##Nat.sub 10 3" of
          Left err -> crash $ "Compilation failed: " ++ err
          Right wat -> do
            expect ("i64.sub" `isInfixOf` wat),
      scope "mul" $ do
        case compileToWat "mul" "##Nat.* 5 6" of
          Left err -> crash $ "Compilation failed: " ++ err
          Right wat -> do
            expect ("i64.mul" `isInfixOf` wat),
      scope "compound_expression" $ do
        -- (3 + 4) - 2
        case compileToWat "compound" "##Nat.sub (##Nat.+ 3 4) 2" of
          Left err -> crash $ "Compilation failed: " ++ err
          Right wat -> do
            expect ("i64.add" `isInfixOf` wat)
            expect ("i64.sub" `isInfixOf` wat)
    ]

--------------------------------------------------------------------------------
-- Foreign Call Tests
--------------------------------------------------------------------------------

-- Note: Foreign call tests are in Abilities.hs since they require manually
-- constructed ANormal IR (the parser doesn't resolve foreign func references
-- in the unit test context without the full codebase environment).

-- NOTE: These unit tests cover IR generation.
-- For comprehensive end-to-end tests including pattern matching, recursion,
-- closures, and sum types, see Integration.hs which runs the generated WAT.
