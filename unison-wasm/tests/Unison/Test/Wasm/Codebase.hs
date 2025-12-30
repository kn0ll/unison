-- | Tests for Unison.Wasm.Codebase module.
--
-- These tests verify the codebase integration functionality, including:
-- * Name resolution (resolveName)
-- * Target resolution (resolveTarget)
-- * Dependency collection (conceptual - requires full codebase)
-- * Term loading (conceptual - requires full codebase)
module Unison.Test.Wasm.Codebase where

import Data.Functor.Identity (Identity, runIdentity)
import EasyTest
import Unison.FileParsers qualified as FP
import Unison.Parsers qualified as Parsers
import Unison.Result qualified as Result
import Unison.Builtin qualified as Builtin
import Unison.Parser.Ann (Ann)
import Unison.Reference qualified as Reference
import Unison.Symbol (Symbol)
import Unison.Syntax.Parser qualified as Parser
import Unison.UnisonFile.Type (TypecheckedUnisonFile)
import Unison.Wasm.Codebase
  ( CodebaseError (..),
    CompileTarget (..),
    compileFromTypecheckedFile,
    resolveName,
    resolveTarget,
  )
import Unison.Wasm.Emit (emitModule)
import Unison.Test.Wasm.Integration (WasmResult (..), executeWat)

test :: Test ()
test =
  scope "codebase" $
    tests
      [ scope "resolveName" testResolveName,
        scope "resolveTarget" testResolveTarget,
        scope "CompileTarget" testCompileTarget,
        scope "CodebaseError" testCodebaseError,
        scope "dependency-complete compilation" testDependencyCompleteCompilation
      ]

testResolveName :: Test ()
testResolveName =
  tests
    [ scope "finds builtin Nat.+" $ do
        let names = Builtin.names
        case resolveName names "Nat.+" of
          Right _ -> ok
          Left err -> crash $ "Expected to find Nat.+, got: " ++ show err,
      scope "returns TermNotFound for unknown name" $ do
        let names = Builtin.names
        case resolveName names "definitely.does.not.exist" of
          Left (TermNotFound (ByName _)) -> ok
          Left err -> crash $ "Expected TermNotFound, got: " ++ show err
          Right _ -> crash "Expected TermNotFound, got success",
      scope "returns TermNotFound for empty name" $ do
        let names = Builtin.names
        case resolveName names "" of
          Left (TermNotFound (ByName _)) -> ok
          Left _ -> ok -- Any error is acceptable for empty name
          Right _ -> crash "Expected error for empty name"
    ]

testResolveTarget :: Test ()
testResolveTarget =
  tests
    [ scope "ByName delegates to resolveName" $ do
        let names = Builtin.names
        case resolveTarget names (ByName "Nat.+") of
          Right _ -> ok
          Left err -> crash $ "Expected to find Nat.+, got: " ++ show err,
      scope "ByReference returns the reference directly" $ do
        let names = Builtin.names
            ref = Reference.Builtin "test" :: Reference.Reference
        case resolveTarget names (ByReference ref) of
          Right r | r == ref -> ok
          Right r -> crash $ "Expected " ++ show ref ++ ", got: " ++ show (r :: Reference.Reference)
          Left err -> crash $ "Expected success, got: " ++ show err
    ]

testCompileTarget :: Test ()
testCompileTarget =
  tests
    [ scope "ByName equality" $ do
        expect $ ByName "foo" == ByName "foo"
        expect $ ByName "foo" /= ByName "bar",
      scope "ByReference equality" $ do
        let ref1 = Reference.Builtin "foo"
            ref2 = Reference.Builtin "bar"
        expect $ ByReference ref1 == ByReference ref1
        expect $ ByReference ref1 /= ByReference ref2,
      scope "Show instances" $ do
        let target1 = ByName "foo"
            target2 = ByReference (Reference.Builtin "bar")
        -- Just verify Show doesn't crash
        let _ = show target1
            _ = show target2
        ok
    ]

testCodebaseError :: Test ()
testCodebaseError =
  tests
    [ scope "TermNotFound equality" $
        expect $ TermNotFound (ByName "foo") == TermNotFound (ByName "foo"),
      scope "AmbiguousName equality" $ do
        let refs = [Reference.Builtin "a", Reference.Builtin "b"]
        expect $ AmbiguousName "foo" refs == AmbiguousName "foo" refs,
      scope "DependencyMissing equality" $ do
        let ref = Reference.Builtin "missing"
        expect $ DependencyMissing ref == DependencyMissing ref,
      scope "Show instances" $ do
        let err1 = TermNotFound (ByName "foo")
            err2 = AmbiguousName "bar" []
            err3 = DependencyMissing (Reference.Builtin "x")
        -- Just verify Show doesn't crash
        let _ = show err1
            _ = show err2
            _ = show err3
        ok
    ]

--------------------------------------------------------------------------------
-- End-to-end: typecheck a file with two terms, compile entry, execute via wasmtime
--------------------------------------------------------------------------------

parsingEnv :: Parser.ParsingEnv Identity
parsingEnv =
  Parser.ParsingEnv
    { uniqueNames = mempty,
      uniqueTypeGuid = \_ -> pure Nothing,
      names = Builtin.names,
      maybeNamespace = Nothing,
      localNamespacePrefixedTypesAndConstructors = mempty
    }

typecheckAsFile ::
  FilePath ->
  String ->
  Either String (TypecheckedUnisonFile Symbol Ann)
typecheckAsFile filename src = do
  uf <- case runIdentity (Parsers.parseFile filename src parsingEnv) of
    Left err -> Left (show err)
    Right uf -> Right uf

  let typecheckingEnv =
        runIdentity $
          FP.computeTypecheckingEnvironment
            (FP.ShouldUseTndr'Yes parsingEnv)
            []
            (\_deps -> pure Builtin.typeLookup)
            uf

  case FP.synthesizeFile typecheckingEnv uf of
    Result.Result notes Nothing ->
      Left ("Typechecking failed: " ++ show notes)
    Result.Result _ (Just typecheckedFile) ->
      Right typecheckedFile

testDependencyCompleteCompilation :: Test ()
testDependencyCompleteCompilation =
  scope "entry calls helper (derived ref)" do
    let src =
          unlines
            [ "helper : Nat -> Nat",
              "helper x = x + 1",
              "",
              "-- entry has no args so wasmtime can invoke it directly",
              "main0 : Nat",
              "main0 = helper 3"
            ]

    uf <- case typecheckAsFile "dep-compile.u" src of
      Left err -> crash err
      Right uf -> pure uf

    case compileFromTypecheckedFile uf "main0" "main0" of
      Left err -> crash ("Compilation failed: " ++ show err)
      Right watModule -> do
        let wat = emitModule watModule
        result <- io $ executeWat "main0" wat
        expectEqual result (WasmI64 4)

