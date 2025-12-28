-- | WAT (WebAssembly Text Format) emitter.
--
-- This module provides functions to emit WAT text format for WASM instructions.
-- The WatInstr/WatFunction/WatModule types serve as an intermediate representation
-- between SuperGroup compilation and WAT text output.
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
  )
where

import Data.Word (Word64)

-- | WASM value types
data WatValType
  = I64
  | F64
  deriving (Eq, Show)

-- | WASM instructions (subset needed for current phases)
data WatInstr
  = -- | Get a local variable: @local.get $name@
    LocalGet String
  | -- | Set a local variable: @local.set $name@
    LocalSet String
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
  | -- | i64 unsigned remainder: @i64.rem_u@
    I64RemU
  | -- | i64 signed remainder: @i64.rem_s@
    I64RemS
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
  | -- | f64 constant: @f64.const n@
    F64Const Double
  | -- | f64 addition: @f64.add@
    F64Add
  | -- | f64 subtraction: @f64.sub@
    F64Sub
  | -- | f64 multiplication: @f64.mul@
    F64Mul
  | -- | f64 division: @f64.div@
    F64Div
  | -- | f64 equality: @f64.eq@
    F64Eq
  | -- | f64 not equal: @f64.ne@
    F64Ne
  | -- | f64 less than: @f64.lt@
    F64Lt
  | -- | f64 less than or equal: @f64.le@
    F64Le
  | -- | f64 greater than: @f64.gt@
    F64Gt
  | -- | f64 greater than or equal: @f64.ge@
    F64Ge
  | -- | Call a function: @call $name@
    Call String
  | -- | Conditional branch: @if (result type) ... else ... end@
    If WatValType [WatInstr] [WatInstr]
  | -- | Block for structured control flow
    Block String [WatInstr]
  | -- | Loop for structured control flow
    Loop String [WatInstr]
  | -- | Branch to label: @br $label@
    Br String
  | -- | Conditional branch: @br_if $label@
    BrIf String
  | -- | Return from function
    Return
  deriving (Eq, Show)

-- | A WASM function definition
data WatFunction = WatFunction
  { funcName :: String,
    -- | Parameter names and types
    funcParams :: [(String, WatValType)],
    -- | Local variable names and types (non-parameter locals)
    funcLocals :: [(String, WatValType)],
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
emitValType F64 = "f64"

-- | Emit a single instruction to WAT text
emitInstr :: WatInstr -> String
emitInstr (LocalGet name) = "local.get $" ++ name
emitInstr (LocalSet name) = "local.set $" ++ name
emitInstr (I64Const n) = "i64.const " ++ show n
emitInstr I64Add = "i64.add"
emitInstr I64Sub = "i64.sub"
emitInstr I64Mul = "i64.mul"
emitInstr I64DivU = "i64.div_u"
emitInstr I64DivS = "i64.div_s"
emitInstr I64RemU = "i64.rem_u"
emitInstr I64RemS = "i64.rem_s"
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
emitInstr (F64Const f) = "f64.const " ++ show f
emitInstr F64Add = "f64.add"
emitInstr F64Sub = "f64.sub"
emitInstr F64Mul = "f64.mul"
emitInstr F64Div = "f64.div"
emitInstr F64Eq = "f64.eq"
emitInstr F64Ne = "f64.ne"
emitInstr F64Lt = "f64.lt"
emitInstr F64Le = "f64.le"
emitInstr F64Gt = "f64.gt"
emitInstr F64Ge = "f64.ge"
emitInstr (Call name) = "call $" ++ name
emitInstr (If resultTy thenInstrs elseInstrs) =
  unlines $
    ["if (result " ++ emitValType resultTy ++ ")"]
      ++ map (("  " ++) . emitInstr) thenInstrs
      ++ ["else"]
      ++ map (("  " ++) . emitInstr) elseInstrs
      ++ ["end"]
emitInstr (Block label instrs) =
  unlines $
    ["block $" ++ label]
      ++ map (("  " ++) . emitInstr) instrs
      ++ ["end"]
emitInstr (Loop label instrs) =
  unlines $
    ["loop $" ++ label]
      ++ map (("  " ++) . emitInstr) instrs
      ++ ["end"]
emitInstr (Br label) = "br $" ++ label
emitInstr (BrIf label) = "br_if $" ++ label
emitInstr Return = "return"

-- | Emit a function definition to WAT text
emitFunction :: WatFunction -> String
emitFunction func =
  unlines
    [ "  (func $" ++ funcName func ++ params ++ results,
      locals,
      body,
      "  )"
    ]
  where
    params =
      concatMap
        (\(name, ty) -> " (param $" ++ name ++ " " ++ emitValType ty ++ ")")
        (funcParams func)
    locals =
      if null (funcLocals func)
        then ""
        else
          unlines $
            map
              (\(name, ty) -> "    (local $" ++ name ++ " " ++ emitValType ty ++ ")")
              (funcLocals func)
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
