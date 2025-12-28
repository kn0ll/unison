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
    [ scope "i32" $ expectEqual (emitValType I32) "i32",
      scope "i64" $ expectEqual (emitValType I64) "i64",
      scope "f64" $ expectEqual (emitValType F64) "f64"
    ]

testInstructions :: Test ()
testInstructions =
  scope "instructions" . tests $
    [ -- Locals and globals
      scope "local.get" $ expectEqual (emitInstr (LocalGet "n")) "local.get $n",
      scope "local.get_x" $ expectEqual (emitInstr (LocalGet "x")) "local.get $x",
      scope "local.set" $ expectEqual (emitInstr (LocalSet "n")) "local.set $n",
      scope "global.get" $ expectEqual (emitInstr (GlobalGet "heap_ptr")) "global.get $heap_ptr",
      scope "global.set" $ expectEqual (emitInstr (GlobalSet "heap_ptr")) "global.set $heap_ptr",
      
      -- i32 operations (Phase 3)
      scope "i32.const_0" $ expectEqual (emitInstr (I32Const 0)) "i32.const 0",
      scope "i32.const_16384" $ expectEqual (emitInstr (I32Const 16384)) "i32.const 16384",
      scope "i32.add" $ expectEqual (emitInstr I32Add) "i32.add",
      scope "i32.sub" $ expectEqual (emitInstr I32Sub) "i32.sub",
      scope "i32.and" $ expectEqual (emitInstr I32And) "i32.and",
      scope "i32.or" $ expectEqual (emitInstr I32Or) "i32.or",
      scope "i32.shl" $ expectEqual (emitInstr I32Shl) "i32.shl",
      scope "i32.shr_u" $ expectEqual (emitInstr I32ShrU) "i32.shr_u",
      scope "i32.eq" $ expectEqual (emitInstr I32Eq) "i32.eq",
      scope "i32.ne" $ expectEqual (emitInstr I32Ne) "i32.ne",
      scope "i32.lt_u" $ expectEqual (emitInstr I32LtU) "i32.lt_u",
      scope "i32.ge_u" $ expectEqual (emitInstr I32GeU) "i32.ge_u",
      scope "i32.wrap_i64" $ expectEqual (emitInstr I32WrapI64) "i32.wrap_i64",
      scope "i64.extend_i32_u" $ expectEqual (emitInstr I64ExtendI32U) "i64.extend_i32_u",
      
      -- Memory operations (Phase 3)
      scope "i32.load" $ expectEqual (emitInstr (I32Load 0)) "i32.load offset=0",
      scope "i32.load_offset" $ expectEqual (emitInstr (I32Load 8)) "i32.load offset=8",
      scope "i32.store" $ expectEqual (emitInstr (I32Store 0)) "i32.store offset=0",
      scope "i64.load" $ expectEqual (emitInstr (I64Load 0)) "i64.load offset=0",
      scope "i64.store" $ expectEqual (emitInstr (I64Store 8)) "i64.store offset=8",
      scope "i32.load8_u" $ expectEqual (emitInstr (I32Load8U 0)) "i32.load8_u offset=0",
      scope "i32.store8" $ expectEqual (emitInstr (I32Store8 0)) "i32.store8 offset=0",
      
      -- i64 operations
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
      scope "i64.and" $ expectEqual (emitInstr I64And) "i64.and",
      scope "i64.or" $ expectEqual (emitInstr I64Or) "i64.or",
      scope "i64.shl" $ expectEqual (emitInstr I64Shl) "i64.shl",
      scope "i64.shr_u" $ expectEqual (emitInstr I64ShrU) "i64.shr_u",
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
      
      -- f64 operations
      scope "f64.const" $ expectEqual (emitInstr (F64Const 3.14)) "f64.const 3.14",
      scope "f64.add" $ expectEqual (emitInstr F64Add) "f64.add",
      scope "f64.sub" $ expectEqual (emitInstr F64Sub) "f64.sub",
      scope "f64.mul" $ expectEqual (emitInstr F64Mul) "f64.mul",
      scope "f64.div" $ expectEqual (emitInstr F64Div) "f64.div",
      
      -- Control flow
      scope "call" $ expectEqual (emitInstr (Call "myFunc")) "call $myFunc",
      scope "return" $ expectEqual (emitInstr Return) "return",
      scope "br" $ expectEqual (emitInstr (Br "loop")) "br $loop",
      scope "br_if" $ expectEqual (emitInstr (BrIf "exit")) "br_if $exit",
      scope "br_table" $ expectEqual (emitInstr (BrTable ["case0", "case1"] "default")) "br_table $case0 $case1 $default",
      scope "unreachable" $ expectEqual (emitInstr Unreachable) "unreachable",
      scope "drop" $ expectEqual (emitInstr Drop) "drop"
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
                { moduleMemory = Nothing,
                  moduleGlobals = [],
                  moduleFunctions = [],
                  moduleExports = [],
                  moduleMemoryExport = Nothing
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
                { moduleMemory = Nothing,
                  moduleGlobals = [],
                  moduleFunctions = [func],
                  moduleExports = ["myFunc"],
                  moduleMemoryExport = Nothing
                }
        let wat = emitModule m
        expect ("export \"myFunc\"" `isInfixOf` wat)
        expect ("func $myFunc" `isInfixOf` wat),
      scope "multiple_functions" $ do
        let f1 = WatFunction "f1" [] [] [I64] [I64Const 1]
            f2 = WatFunction "f2" [] [] [I64] [I64Const 2]
        let m =
              WatModule
                { moduleMemory = Nothing,
                  moduleGlobals = [],
                  moduleFunctions = [f1, f2],
                  moduleExports = ["f1", "f2"],
                  moduleMemoryExport = Nothing
                }
        let wat = emitModule m
        expect ("func $f1" `isInfixOf` wat)
        expect ("func $f2" `isInfixOf` wat)
        expect ("export \"f1\"" `isInfixOf` wat)
        expect ("export \"f2\"" `isInfixOf` wat),
      scope "with_memory" $ do
        let m =
              WatModule
                { moduleMemory = Just 1,  -- 1 page = 64KB
                  moduleGlobals = [],
                  moduleFunctions = [],
                  moduleExports = [],
                  moduleMemoryExport = Just "memory"
                }
        let wat = emitModule m
        expect ("(memory 1)" `isInfixOf` wat)
        expect ("export \"memory\"" `isInfixOf` wat),
      scope "with_globals" $ do
        let heapPtr = WatGlobal
              { globalName = "heap_ptr",
                globalType = I32,
                globalMutable = True,
                globalInit = 16384  -- 0x4000
              }
        let m =
              WatModule
                { moduleMemory = Just 1,
                  moduleGlobals = [heapPtr],
                  moduleFunctions = [],
                  moduleExports = [],
                  moduleMemoryExport = Nothing
                }
        let wat = emitModule m
        expect ("global $heap_ptr" `isInfixOf` wat)
        expect ("(mut " `isInfixOf` wat)
        expect ("i32.const 16384" `isInfixOf` wat)
    ]
