-- | WAT (WebAssembly Text Format) emitter for Phase 1.
--
-- This module provides functions to emit WAT text format for basic WASM instructions.
-- Phase 1 only supports unboxed i64 operations with no heap allocation.
module Unison.Wasm.Emit
  ( -- * WAT Types
    WatModule (..),
    WatFunction (..),
    WatInstr (..),
    WatValType (..),

    -- * Emission
    emitModule,
    emitFunction,
    emitInstr,
    emitValType,

    -- * Hardcoded Functions (Phase 1)
    incrementModule,
    incrementFunction,
  )
where

import Data.Word (Word64)

-- | WASM value types (Phase 1: only i64)
data WatValType
  = I64
  deriving (Eq, Show)

-- | WASM instructions (Phase 1 subset: arithmetic only)
data WatInstr
  = -- | Get a local variable: @local.get $name@
    LocalGet String
  | -- | i64 constant: @i64.const n@
    I64Const Word64
  | -- | i64 addition: @i64.add@
    I64Add
  | -- | i64 subtraction: @i64.sub@
    I64Sub
  | -- | i64 multiplication: @i64.mul@
    I64Mul
  | -- | i64 unsigned division: @i64.div_u@
    I64DivU
  | -- | i64 signed division: @i64.div_s@
    I64DivS
  | -- | i64 equality: @i64.eq@
    I64Eq
  | -- | i64 not equal: @i64.ne@
    I64Ne
  | -- | i64 less than unsigned: @i64.lt_u@
    I64LtU
  | -- | i64 less than signed: @i64.lt_s@
    I64LtS
  | -- | i64 less than or equal unsigned: @i64.le_u@
    I64LeU
  | -- | i64 less than or equal signed: @i64.le_s@
    I64LeS
  | -- | i64 greater than unsigned: @i64.gt_u@
    I64GtU
  | -- | i64 greater than signed: @i64.gt_s@
    I64GtS
  | -- | i64 greater than or equal unsigned: @i64.ge_u@
    I64GeU
  | -- | i64 greater than or equal signed: @i64.ge_s@
    I64GeS
  deriving (Eq, Show)

-- | A WASM function definition
data WatFunction = WatFunction
  { funcName :: String,
    -- | Parameter names and types
    funcParams :: [(String, WatValType)],
    -- | Result types
    funcResults :: [WatValType],
    -- | Function body instructions
    funcBody :: [WatInstr]
  }
  deriving (Eq, Show)

-- | A WASM module
data WatModule = WatModule
  { -- | Functions defined in this module
    moduleFunctions :: [WatFunction],
    -- | Exported function names (must reference functions in moduleFunctions)
    moduleExports :: [String]
  }
  deriving (Eq, Show)

-- | Emit a value type to WAT text
emitValType :: WatValType -> String
emitValType I64 = "i64"

-- | Emit a single instruction to WAT text
emitInstr :: WatInstr -> String
emitInstr (LocalGet name) = "local.get $" ++ name
emitInstr (I64Const n) = "i64.const " ++ show n
emitInstr I64Add = "i64.add"
emitInstr I64Sub = "i64.sub"
emitInstr I64Mul = "i64.mul"
emitInstr I64DivU = "i64.div_u"
emitInstr I64DivS = "i64.div_s"
emitInstr I64Eq = "i64.eq"
emitInstr I64Ne = "i64.ne"
emitInstr I64LtU = "i64.lt_u"
emitInstr I64LtS = "i64.lt_s"
emitInstr I64LeU = "i64.le_u"
emitInstr I64LeS = "i64.le_s"
emitInstr I64GtU = "i64.gt_u"
emitInstr I64GtS = "i64.gt_s"
emitInstr I64GeU = "i64.ge_u"
emitInstr I64GeS = "i64.ge_s"

-- | Emit a function definition to WAT text
emitFunction :: WatFunction -> String
emitFunction func =
  unlines
    [ "  (func $" ++ funcName func ++ params ++ results,
      body,
      "  )"
    ]
  where
    params =
      concatMap
        (\(name, ty) -> " (param $" ++ name ++ " " ++ emitValType ty ++ ")")
        (funcParams func)
    results =
      if null (funcResults func)
        then ""
        else " (result " ++ unwords (map emitValType (funcResults func)) ++ ")"
    body = unlines $ map (("    " ++) . emitInstr) (funcBody func)

-- | Emit a complete WASM module to WAT text
emitModule :: WatModule -> String
emitModule m =
  unlines $
    ["(module"]
      ++ map emitFunction (moduleFunctions m)
      ++ map emitExport (moduleExports m)
      ++ [")"]
  where
    emitExport name =
      "  (export \"" ++ name ++ "\" (func $" ++ name ++ "))"

--------------------------------------------------------------------------------
-- Hardcoded Functions (Phase 1)
--------------------------------------------------------------------------------

-- | The hardcoded @increment@ function: @increment n = n + 1@
--
-- Corresponds to Unison:
-- @
-- increment : Nat -> Nat
-- increment n = n + 1
-- @
--
-- And SuperNormal (approximately):
-- @
-- Lambda [UN] (TLets Direct [(result, UN)] (TPrm ADDN [n, 1]) (TVar result))
-- @
incrementFunction :: WatFunction
incrementFunction =
  WatFunction
    { funcName = "increment",
      funcParams = [("n", I64)],
      funcResults = [I64],
      funcBody =
        [ LocalGet "n",
          I64Const 1,
          I64Add
        ]
    }

-- | A complete module exporting just the @increment@ function
incrementModule :: WatModule
incrementModule =
  WatModule
    { moduleFunctions = [incrementFunction],
      moduleExports = ["increment"]
    }
