-- | Tests for WAT emission (Phase 1).
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
      testModule,
      testIncrement
    ]

testValTypes :: Test ()
testValTypes =
  scope "valTypes" . tests $
    [ scope "i64" $ expectEqual (emitValType I64) "i64"
    ]

testInstructions :: Test ()
testInstructions =
  scope "instructions" . tests $
    [ scope "local.get" $ expectEqual (emitInstr (LocalGet "n")) "local.get $n",
      scope "local.get_x" $ expectEqual (emitInstr (LocalGet "x")) "local.get $x",
      scope "i64.const_0" $ expectEqual (emitInstr (I64Const 0)) "i64.const 0",
      scope "i64.const_1" $ expectEqual (emitInstr (I64Const 1)) "i64.const 1",
      scope "i64.const_42" $ expectEqual (emitInstr (I64Const 42)) "i64.const 42",
      scope "i64.const_large" $ expectEqual (emitInstr (I64Const 18446744073709551615)) "i64.const 18446744073709551615",
      scope "i64.add" $ expectEqual (emitInstr I64Add) "i64.add",
      scope "i64.sub" $ expectEqual (emitInstr I64Sub) "i64.sub",
      scope "i64.mul" $ expectEqual (emitInstr I64Mul) "i64.mul",
      scope "i64.div_u" $ expectEqual (emitInstr I64DivU) "i64.div_u",
      scope "i64.div_s" $ expectEqual (emitInstr I64DivS) "i64.div_s",
      scope "i64.eq" $ expectEqual (emitInstr I64Eq) "i64.eq",
      scope "i64.ne" $ expectEqual (emitInstr I64Ne) "i64.ne",
      scope "i64.lt_u" $ expectEqual (emitInstr I64LtU) "i64.lt_u",
      scope "i64.lt_s" $ expectEqual (emitInstr I64LtS) "i64.lt_s",
      scope "i64.le_u" $ expectEqual (emitInstr I64LeU) "i64.le_u",
      scope "i64.le_s" $ expectEqual (emitInstr I64LeS) "i64.le_s",
      scope "i64.gt_u" $ expectEqual (emitInstr I64GtU) "i64.gt_u",
      scope "i64.gt_s" $ expectEqual (emitInstr I64GtS) "i64.gt_s",
      scope "i64.ge_u" $ expectEqual (emitInstr I64GeU) "i64.ge_u",
      scope "i64.ge_s" $ expectEqual (emitInstr I64GeS) "i64.ge_s"
    ]

testFunction :: Test ()
testFunction =
  scope "function" . tests $
    [ scope "simple" $ do
        let func =
              WatFunction
                { funcName = "add",
                  funcParams = [("a", I64), ("b", I64)],                  funcLocals = [],                  funcResults = [I64],
                  funcBody = [LocalGet "a", LocalGet "b", I64Add]
                }
        let wat = emitFunction func
        expect ("func $add" `isInfixOf` wat),
      scope "params" $ do
        let func =
              WatFunction
                { funcName = "test",
                  funcParams = [("x", I64)],
                  funcLocals = [],
                  funcResults = [],
                  funcBody = []
                }
        let wat = emitFunction func
        expect ("param $x i64" `isInfixOf` wat),
      scope "results" $ do
        let func =
              WatFunction
                { funcName = "test",
                  funcParams = [],
                  funcLocals = [],
                  funcResults = [I64],
                  funcBody = []
                }
        let wat = emitFunction func
        expect ("result i64" `isInfixOf` wat),
      scope "body" $ do
        let func =
              WatFunction
                { funcName = "test",
                  funcParams = [],
                  funcLocals = [],
                  funcResults = [I64],
                  funcBody = [I64Const 42]
                }
        let wat = emitFunction func
        expect ("i64.const 42" `isInfixOf` wat)
    ]

testModule :: Test ()
testModule =
  scope "module" . tests $
    [ scope "wrapping" $ do
        let m =
              WatModule
                { moduleFunctions = [],
                  moduleExports = []
                }
        let wat = emitModule m
        expect ("(module" `isInfixOf` wat)
        expect (")" `isInfixOf` wat),
      scope "exports" $ do
        let func =
              WatFunction
                { funcName = "test",
                  funcParams = [],
                  funcLocals = [],
                  funcResults = [I64],
                  funcBody = [I64Const 0]
                }
        let m =
              WatModule
                { moduleFunctions = [func],
                  moduleExports = ["test"]
                }
        let wat = emitModule m
        expect ("export \"test\"" `isInfixOf` wat)
        expect ("func $test" `isInfixOf` wat)
    ]

testIncrement :: Test ()
testIncrement =
  scope "increment" . tests $
    [ scope "function_name" $ do
        expectEqual (funcName incrementFunction) "increment",
      scope "params" $ do
        expectEqual (funcParams incrementFunction) [("n", I64)],
      scope "results" $ do
        expectEqual (funcResults incrementFunction) [I64],
      scope "body" $ do
        expectEqual (funcBody incrementFunction) [LocalGet "n", I64Const 1, I64Add],
      scope "module_exports" $ do
        expectEqual (moduleExports incrementModule) ["increment"],
      scope "module_functions" $ do
        expectEqual (length (moduleFunctions incrementModule)) 1,
      scope "wat_output" $ do
        let wat = emitModule incrementModule
        -- Verify the WAT contains expected structure
        expect ("(module" `isInfixOf` wat)
        expect ("func $increment" `isInfixOf` wat)
        expect ("param $n i64" `isInfixOf` wat)
        expect ("result i64" `isInfixOf` wat)
        expect ("local.get $n" `isInfixOf` wat)
        expect ("i64.const 1" `isInfixOf` wat)
        expect ("i64.add" `isInfixOf` wat)
        expect ("export \"increment\"" `isInfixOf` wat)
    ]
