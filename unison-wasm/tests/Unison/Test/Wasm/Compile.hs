-- | Tests for the SuperGroup → WAT compiler.
module Unison.Test.Wasm.Compile where

import Data.Text qualified as Text
import Data.Word (Word64)
import EasyTest
import Unison.ABT.Normalized qualified as ABTN
import Unison.Reference (Reference)
import Unison.Reference qualified as Reference
import Unison.Runtime.ANF
  ( ANormalF,
    Branched (..),
    Direction (..),
    Func (..),
    Lit (..),
    Mem (..),
    SuperGroup (..),
    SuperNormal (..),
    pattern TApp,
    pattern TLets,
    pattern TLit,
    pattern TMatch,
    pattern TPrm,
    pattern TVar,
  )
import Unison.Runtime.ANF.POp (POp (..))
import Unison.Symbol (Symbol)
import Unison.Util.EnumContainers qualified as EC
import Unison.Var qualified as Var
import Unison.Wasm.Compile
  ( CompileError (..),
    compileGroup,
    compileSuperNormal,
  )
import Unison.Wasm.Emit
  ( WatFunction (..),
    WatInstr (..),
    WatModule (..),
    WatValType (..),
  )

-- | Helper to create a Symbol from a string
sym :: String -> Symbol
sym = Var.named . Text.pack

-- | Type alias for our ANormal terms
type ANorm = ABTN.Term (ANormalF Reference) Symbol

-- | Create a TLit (Nat literal) ANormal term
natLit :: Word64 -> ANorm
natLit n = TLit (N n)

-- | Create a TVar ANormal term
var :: String -> ANorm
var s = TVar (sym s)

-- | Create a TPrm ANormal term
prim :: POp -> [Symbol] -> ANorm
prim op args = TPrm op args

-- | Create a SuperNormal
-- For Phase 2, we need to wrap the body in Abs nodes for parameters
-- so that the compiler can extract the parameter names properly.
sn :: [Mem] -> ANorm -> SuperNormal Reference Symbol
sn mems body = Lambda mems (wrapAbs mems 0 body)
  where
    -- Wrap the body in TAbs nodes for each parameter (p0, p1, etc.)
    wrapAbs :: [Mem] -> Int -> ANorm -> ANorm
    wrapAbs [] _ b = b
    wrapAbs (_:rest) i b =
      ABTN.TAbs (sym $ "p" ++ show i) (wrapAbs rest (i + 1) b)

-- | Create a SuperGroup with just an entry function
sg :: SuperNormal Reference Symbol -> SuperGroup Reference Symbol
sg entry = Rec [] entry

test :: Test ()
test =
  scope "compile" . tests $
    [ testLiteralCompilation,
      testVariableCompilation,
      testPrimOpCompilation,
      testFunctionStructure,
      testMatchIntegral,
      testRecursion,
      testErrors
    ]

--------------------------------------------------------------------------------
-- Literal Tests
--------------------------------------------------------------------------------

testLiteralCompilation :: Test ()
testLiteralCompilation =
  scope "literals" . tests $
    [ scope "nat_42" $ do
        -- SuperNormal: Lambda [] (TLit (N 42))
        let superN = sn [] (natLit 42)
        case compileSuperNormal superN "constNat" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> do
            expectEqual (funcName func) "constNat"
            expectEqual (funcResults func) [I64]
            expect $ I64Const 42 `elem` funcBody func,
      scope "nat_0" $ do
        let superN = sn [] (natLit 0)
        case compileSuperNormal superN "zero" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> expect $ I64Const 0 `elem` funcBody func,
      scope "large_nat" $ do
        let superN = sn [] (natLit 0xFFFFFFFFFFFFFFFF)
        case compileSuperNormal superN "maxNat" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> expect $ I64Const 0xFFFFFFFFFFFFFFFF `elem` funcBody func,
      scope "float_3.14" $ do
        -- Float literal: 3.14
        let superN = sn [] (TLit (F 3.14))
        case compileSuperNormal superN "pi" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> do
            expectEqual (funcResults func) [I64]  -- Still i64 result type (Phase 2 limitation)
            expect $ F64Const 3.14 `elem` funcBody func,
      scope "char_A" $ do
        -- Char literal: 'A' (codepoint 65)
        let superN = sn [] (TLit (C 'A'))
        case compileSuperNormal superN "charA" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> do
            expectEqual (funcResults func) [I64]
            expect $ I64Const 65 `elem` funcBody func,
      scope "char_unicode" $ do
        -- Unicode char: '🦄' (codepoint 129412 / 0x1F984)
        let superN = sn [] (TLit (C '🦄'))
        case compileSuperNormal superN "unicorn" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> do
            expect $ I64Const 129412 `elem` funcBody func
    ]

--------------------------------------------------------------------------------
-- Variable Tests
--------------------------------------------------------------------------------

testVariableCompilation :: Test ()
testVariableCompilation =
  scope "variables" . tests $
    [ scope "identity_nat" $ do
        -- Lambda [UN] (TVar p0) -- identity function
        let superN = sn [UN] (var "p0")
        case compileSuperNormal superN "identity" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> do
            expectEqual (funcParams func) [("p0", I64)]
            expectEqual (funcResults func) [I64]
            expect $ LocalGet "p0" `elem` funcBody func,
      scope "two_params_return_first" $ do
        -- Lambda [UN, UN] (TVar p0) -- return first param
        let superN = sn [UN, UN] (var "p0")
        case compileSuperNormal superN "first" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> do
            expectEqual (length $ funcParams func) 2
    ]

--------------------------------------------------------------------------------
-- Primitive Operation Tests
--------------------------------------------------------------------------------

testPrimOpCompilation :: Test ()
testPrimOpCompilation =
  scope "primops" . tests $
    [ scope "addn" $ do
        -- Lambda [UN, UN] (TPrm ADDN [p0, p1])
        let superN = sn [UN, UN] (prim ADDN [sym "p0", sym "p1"])
        case compileSuperNormal superN "add" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> do
            expect $ I64Add `elem` funcBody func,
      scope "subn" $ do
        let superN = sn [UN, UN] (prim SUBN [sym "p0", sym "p1"])
        case compileSuperNormal superN "sub" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> do
            expect $ I64Sub `elem` funcBody func,
      scope "muln" $ do
        let superN = sn [UN, UN] (prim MULN [sym "p0", sym "p1"])
        case compileSuperNormal superN "mul" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> do
            expect $ I64Mul `elem` funcBody func,
      scope "divn" $ do
        let superN = sn [UN, UN] (prim DIVN [sym "p0", sym "p1"])
        case compileSuperNormal superN "div" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> do
            expect $ I64DivU `elem` funcBody func,
      scope "eqln" $ do
        let superN = sn [UN, UN] (prim EQLN [sym "p0", sym "p1"])
        case compileSuperNormal superN "eq" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> do
            expect $ I64Eq `elem` funcBody func,
      scope "lesn" $ do
        let superN = sn [UN, UN] (prim LESN [sym "p0", sym "p1"])
        case compileSuperNormal superN "lt" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> do
            expect $ I64LtU `elem` funcBody func
    ]

--------------------------------------------------------------------------------
-- Function Structure Tests
--------------------------------------------------------------------------------

testFunctionStructure :: Test ()
testFunctionStructure =
  scope "structure" . tests $
    [ scope "no_params" $ do
        let superN = sn [] (natLit 42)
        case compileSuperNormal superN "const42" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> do
            expectEqual (funcParams func) [],
      scope "one_param" $ do
        let superN = sn [UN] (var "p0")
        case compileSuperNormal superN "identity" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> do
            expectEqual (length $ funcParams func) 1,
      scope "three_params" $ do
        let superN = sn [UN, UN, UN] (var "p0")
        case compileSuperNormal superN "threeArgs" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> do
            expectEqual (length $ funcParams func) 3,
      scope "group_export" $ do
        let superN = sn [] (natLit 1)
            group = sg superN
        case compileGroup group "myExport" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right wasm -> do
            expectEqual (moduleExports wasm) ["myExport"]
            expectEqual (length $ moduleFunctions wasm) 1
    ]

--------------------------------------------------------------------------------
-- Error Tests
--------------------------------------------------------------------------------

testErrors :: Test ()
testErrors =
  scope "errors" . tests $
    [ scope "unsupported_primop" $ do
        -- Use an unsupported primop (e.g., text operations)
        let superN = sn [UN, UN] (prim POWN [sym "p0", sym "p1"])
        case compileSuperNormal superN "pow" of
          Left (UnsupportedPrimOp _) -> ok
          Left err -> crash $ "Wrong error: " ++ show err
          Right _ -> crash "Should have failed with UnsupportedPrimOp"
    ]

--------------------------------------------------------------------------------
-- MatchIntegral Tests
--------------------------------------------------------------------------------

testMatchIntegral :: Test ()
testMatchIntegral =
  scope "match_integral" . tests $
    [ scope "simple_case" $ do
        -- match n with { 0 -> 1; _ -> 2 }
        let matchCases = MatchIntegral
              (EC.mapFromList [(0 :: Word64, natLit 1)])
              (Just (natLit 2))
            body = TMatch (sym "p0") matchCases
            superN = sn [UN] body
        case compileSuperNormal superN "test" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> do
            -- Should contain If instruction
            expectAny (isIfInstr) (funcBody func)
    ]
  where
    isIfInstr (If _ _ _) = True
    isIfInstr _ = False

--------------------------------------------------------------------------------
-- Recursion Tests
--------------------------------------------------------------------------------

testRecursion :: Test ()
testRecursion =
  scope "recursion" . tests $
    [ scope "recursive_call" $ do
        -- Simple recursive pattern: let x = f(p0) in x
        -- This tests that TApp FComb compiles to a call
        let callBody = TLets Direct [sym "x"] [UN]
              (TApp (FComb (Reference.Builtin "test")) [sym "p0"])
              (var "x")
            superN = sn [UN] callBody
        case compileSuperNormal superN "test" of
          Left err -> crash $ "Compilation failed: " ++ show err
          Right func -> do
            -- Should contain a Call instruction
            expectAny (isCallInstr) (funcBody func)
    ]
  where
    isCallInstr (Call _) = True
    isCallInstr _ = False

-- | Check if any element in list satisfies predicate
expectAny :: (a -> Bool) -> [a] -> Test ()
expectAny p xs =
  if any p xs
    then ok
    else crash "Expected at least one element to satisfy predicate"
