-- | Tests for WAT emission.
module Unison.Test.Wasm.Emit where

import Data.List (isInfixOf)
import EasyTest
import Unison.Wasm.Emit

test :: Test ()
test =
  scope "emit" . tests $
    [ testValTypes,
      testInstructions,
      testFunction,
      testModule
    ]

testValTypes :: Test ()
testValTypes =
  scope "valTypes" . tests $
    [ scope "i64" $ expectEqual (emitValType I64) "i64",
      scope "f64" $ expectEqual (emitValType F64) "f64"
    ]

testInstructions :: Test ()
testInstructions =
  scope "instructions" . tests $
    [ scope "local.get" $ expectEqual (emitInstr (LocalGet "n")) "local.get $n",
      scope "local.get_x" $ expectEqual (emitInstr (LocalGet "x")) "local.get $x",
      scope "local.set" $ expectEqual (emitInstr (LocalSet "n")) "local.set $n",
      scope "i64.const_0" $ expectEqual (emitInstr (I64Const 0)) "i64.const 0",
      scope "i64.const_1" $ expectEqual (emitInstr (I64Const 1)) "i64.const 1",
      scope "i64.const_42" $ expectEqual (emitInstr (I64Const 42)) "i64.const 42",
      scope "i64.const_large" $ expectEqual (emitInstr (I64Const 18446744073709551615)) "i64.const 18446744073709551615",
      scope "i64.add" $ expectEqual (emitInstr I64Add) "i64.add",
      scope "i64.sub" $ expectEqual (emitInstr I64Sub) "i64.sub",
      scope "i64.mul" $ expectEqual (emitInstr I64Mul) "i64.mul",
      scope "i64.div_u" $ expectEqual (emitInstr I64DivU) "i64.div_u",
      scope "i64.div_s" $ expectEqual (emitInstr I64DivS) "i64.div_s",
      scope "i64.rem_u" $ expectEqual (emitInstr I64RemU) "i64.rem_u",
      scope "i64.rem_s" $ expectEqual (emitInstr I64RemS) "i64.rem_s",
      scope "i64.eq" $ expectEqual (emitInstr I64Eq) "i64.eq",
      scope "i64.ne" $ expectEqual (emitInstr I64Ne) "i64.ne",
      scope "i64.lt_u" $ expectEqual (emitInstr I64LtU) "i64.lt_u",
      scope "i64.lt_s" $ expectEqual (emitInstr I64LtS) "i64.lt_s",
      scope "i64.le_u" $ expectEqual (emitInstr I64LeU) "i64.le_u",
      scope "i64.le_s" $ expectEqual (emitInstr I64LeS) "i64.le_s",
      scope "i64.gt_u" $ expectEqual (emitInstr I64GtU) "i64.gt_u",
      scope "i64.gt_s" $ expectEqual (emitInstr I64GtS) "i64.gt_s",
      scope "i64.ge_u" $ expectEqual (emitInstr I64GeU) "i64.ge_u",
      scope "i64.ge_s" $ expectEqual (emitInstr I64GeS) "i64.ge_s",
      scope "f64.const" $ expectEqual (emitInstr (F64Const 3.14)) "f64.const 3.14",
      scope "f64.add" $ expectEqual (emitInstr F64Add) "f64.add",
      scope "f64.sub" $ expectEqual (emitInstr F64Sub) "f64.sub",
      scope "f64.mul" $ expectEqual (emitInstr F64Mul) "f64.mul",
      scope "f64.div" $ expectEqual (emitInstr F64Div) "f64.div",
      scope "call" $ expectEqual (emitInstr (Call "myFunc")) "call $myFunc",
      scope "return" $ expectEqual (emitInstr Return) "return",
      scope "br" $ expectEqual (emitInstr (Br "loop")) "br $loop",
      scope "br_if" $ expectEqual (emitInstr (BrIf "exit")) "br_if $exit"
    ]

testFunction :: Test ()
testFunction =
  scope "function" . tests $
    [ scope "simple_add" $ do
        let func =
              WatFunction
                { funcName = "add",
                  funcParams = [("a", I64), ("b", I64)],
                  funcLocals = [],
                  funcResults = [I64],
                  funcBody = [LocalGet "a", LocalGet "b", I64Add]
                }
        let wat = emitFunction func
        expect ("func $add" `isInfixOf` wat)
        expect ("param $a i64" `isInfixOf` wat)
        expect ("param $b i64" `isInfixOf` wat)
        expect ("result i64" `isInfixOf` wat)
        expect ("local.get $a" `isInfixOf` wat)
        expect ("i64.add" `isInfixOf` wat),
      scope "with_locals" $ do
        let func =
              WatFunction
                { funcName = "withLocal",
                  funcParams = [("x", I64)],
                  funcLocals = [("tmp", I64)],
                  funcResults = [I64],
                  funcBody = [LocalGet "x", LocalSet "tmp", LocalGet "tmp"]
                }
        let wat = emitFunction func
        expect ("local $tmp i64" `isInfixOf` wat),
      scope "no_params" $ do
        let func =
              WatFunction
                { funcName = "const42",
                  funcParams = [],
                  funcLocals = [],
                  funcResults = [I64],
                  funcBody = [I64Const 42]
                }
        let wat = emitFunction func
        expect ("func $const42" `isInfixOf` wat)
        expect ("i64.const 42" `isInfixOf` wat),
      scope "no_result" $ do
        let func =
              WatFunction
                { funcName = "noop",
                  funcParams = [],
                  funcLocals = [],
                  funcResults = [],
                  funcBody = []
                }
        let wat = emitFunction func
        expect ("func $noop" `isInfixOf` wat)
        expect (not $ "result" `isInfixOf` wat)
    ]

testModule :: Test ()
testModule =
  scope "module" . tests $
    [ scope "empty" $ do
        let m =
              WatModule
                { moduleFunctions = [],
                  moduleExports = []
                }
        let wat = emitModule m
        expect ("(module" `isInfixOf` wat)
        expect (")" `isInfixOf` wat),
      scope "with_export" $ do
        let func =
              WatFunction
                { funcName = "myFunc",
                  funcParams = [],
                  funcLocals = [],
                  funcResults = [I64],
                  funcBody = [I64Const 0]
                }
        let m =
              WatModule
                { moduleFunctions = [func],
                  moduleExports = ["myFunc"]
                }
        let wat = emitModule m
        expect ("export \"myFunc\"" `isInfixOf` wat)
        expect ("func $myFunc" `isInfixOf` wat),
      scope "multiple_functions" $ do
        let f1 = WatFunction "f1" [] [] [I64] [I64Const 1]
            f2 = WatFunction "f2" [] [] [I64] [I64Const 2]
        let m =
              WatModule
                { moduleFunctions = [f1, f2],
                  moduleExports = ["f1", "f2"]
                }
        let wat = emitModule m
        expect ("func $f1" `isInfixOf` wat)
        expect ("func $f2" `isInfixOf` wat)
        expect ("export \"f1\"" `isInfixOf` wat)
        expect ("export \"f2\"" `isInfixOf` wat)
    ]
