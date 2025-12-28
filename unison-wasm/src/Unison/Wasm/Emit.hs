-- | WAT (WebAssembly Text Format) emitter.
--
-- This module provides functions to emit WAT text format for WASM instructions.
-- The WatInstr/WatFunction/WatModule types serve as an intermediate representation
-- between SuperGroup compilation and WAT text output.
--
-- Supports function tables for call_indirect and apply() for closure invocation.
module Unison.Wasm.Emit
  ( -- * WAT Types
    WatModule (..),
    WatFunction (..),
    WatInstr (..),
    WatValType (..),
    WatGlobal (..),
    WatFuncType (..),

    -- * Emission
    emitModule,
    emitFunction,
    emitInstr,
    emitValType,
  )
where

import Data.Word (Word32, Word64)

-- | WASM value types
data WatValType
  = I32  -- ^ 32-bit integer (used for pointers)
  | I64  -- ^ 64-bit integer (used for unboxed values)
  | F64  -- ^ 64-bit float
  deriving (Eq, Show)

-- | WASM global variable
data WatGlobal = WatGlobal
  { globalName :: String,
    globalType :: WatValType,
    globalMutable :: Bool,
    globalInit :: Word64  -- Initial value (also works for i32)
  }
  deriving (Eq, Show)

-- | WASM function type signature (for call_indirect)
data WatFuncType = WatFuncType
  { funcTypeName :: String,
    funcTypeParams :: [WatValType],
    funcTypeResults :: [WatValType]
  }
  deriving (Eq, Show)

-- | WASM instructions (subset needed for current phases)
data WatInstr
  = -- | Get a local variable: @local.get $name@
    LocalGet String
  | -- | Set a local variable: @local.set $name@
    LocalSet String
  | -- | Tee a local variable (set and keep on stack): @local.tee $name@
    LocalTee String
  | -- | Get a global variable: @global.get $name@
    GlobalGet String
  | -- | Set a global variable: @global.set $name@
    GlobalSet String

  -- i32 operations (for pointers)
  | -- | i32 constant: @i32.const n@
    I32Const Word32
  | -- | i32 addition: @i32.add@
    I32Add
  | -- | i32 subtraction: @i32.sub@
    I32Sub
  | -- | i32 multiplication: @i32.mul@
    I32Mul
  | -- | i32 and: @i32.and@
    I32And
  | -- | i32 or: @i32.or@
    I32Or
  | -- | i32 left shift: @i32.shl@
    I32Shl
  | -- | i32 right shift unsigned: @i32.shr_u@
    I32ShrU
  | -- | i32 equality: @i32.eq@
    I32Eq
  | -- | i32 not equal: @i32.ne@
    I32Ne
  | -- | i32 less than unsigned: @i32.lt_u@
    I32LtU
  | -- | i32 greater than or equal unsigned: @i32.ge_u@
    I32GeU
  | -- | i32 wrap i64: @i32.wrap_i64@
    I32WrapI64
  | -- | i64 extend i32 unsigned: @i64.extend_i32_u@
    I64ExtendI32U

  -- Memory operations
  | -- | Load i32 from memory: @i32.load offset=n@
    I32Load Word32  -- offset
  | -- | Store i32 to memory: @i32.store offset=n@
    I32Store Word32  -- offset
  | -- | Load i64 from memory: @i64.load offset=n@
    I64Load Word32  -- offset
  | -- | Store i64 to memory: @i64.store offset=n@
    I64Store Word32  -- offset
  | -- | Load i8 from memory (zero-extend to i32): @i32.load8_u offset=n@
    I32Load8U Word32  -- offset
  | -- | Load i16 from memory (zero-extend to i32): @i32.load16_u offset=n@
    I32Load16U Word32  -- offset
  | -- | Store low 8 bits of i32 to memory: @i32.store8 offset=n@
    I32Store8 Word32  -- offset

  -- i64 operations
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
  | -- | i64 and: @i64.and@
    I64And
  | -- | i64 or: @i64.or@
    I64Or
  | -- | i64 left shift: @i64.shl@
    I64Shl
  | -- | i64 right shift unsigned: @i64.shr_u@
    I64ShrU
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

  -- f64 operations
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

  -- Control flow
  | -- | Call a function: @call $name@
    Call String
  | -- | Indirect function call: @call_indirect (type $typeName)@
    CallIndirect String  -- type name
  | -- | Conditional branch: @if (result type) ... else ... end@
    If WatValType [WatInstr] [WatInstr]
  | -- | If without result (for side effects only)
    IfVoid [WatInstr] [WatInstr]
  | -- | Block for structured control flow
    Block String [WatInstr]
  | -- | Loop for structured control flow
    Loop String [WatInstr]
  | -- | Branch to label: @br $label@
    Br String
  | -- | Conditional branch: @br_if $label@
    BrIf String
  | -- | Branch table: @br_table $l0 $l1 ... $default@
    BrTable [String] String  -- labels, default
  | -- | Return from function
    Return
  | -- | Unreachable (trap): @unreachable@
    Unreachable
  | -- | Drop top of stack: @drop@
    Drop
  | -- | Comment (for debugging): @;; comment@
    Comment String
  | -- | Nop (no operation)
    Nop
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
  { -- | Memory size in pages (64KB each), Nothing = no memory
    moduleMemory :: Maybe Word32,
    -- | Global variables
    moduleGlobals :: [WatGlobal],
    -- | Functions defined in this module
    moduleFunctions :: [WatFunction],
    -- | Exported function names (must reference functions in moduleFunctions)
    moduleExports :: [String],
    -- | Export memory with this name
    moduleMemoryExport :: Maybe String,
    -- | Function types for call_indirect
    moduleFuncTypes :: [WatFuncType],
    -- | Function table entries (function names to include in table)
    moduleTableFuncs :: [String]
  }
  deriving (Eq, Show)

-- | Emit a value type to WAT text
emitValType :: WatValType -> String
emitValType I32 = "i32"
emitValType I64 = "i64"
emitValType F64 = "f64"

-- | Emit a single instruction to WAT text
emitInstr :: WatInstr -> String
emitInstr (LocalGet name) = "local.get $" ++ name
emitInstr (LocalSet name) = "local.set $" ++ name
emitInstr (LocalTee name) = "local.tee $" ++ name
emitInstr (GlobalGet name) = "global.get $" ++ name
emitInstr (GlobalSet name) = "global.set $" ++ name

-- i32 operations
emitInstr (I32Const n) = "i32.const " ++ show n
emitInstr I32Add = "i32.add"
emitInstr I32Sub = "i32.sub"
emitInstr I32Mul = "i32.mul"
emitInstr I32And = "i32.and"
emitInstr I32Or = "i32.or"
emitInstr I32Shl = "i32.shl"
emitInstr I32ShrU = "i32.shr_u"
emitInstr I32Eq = "i32.eq"
emitInstr I32Ne = "i32.ne"
emitInstr I32LtU = "i32.lt_u"
emitInstr I32GeU = "i32.ge_u"
emitInstr I32WrapI64 = "i32.wrap_i64"
emitInstr I64ExtendI32U = "i64.extend_i32_u"

-- Memory operations
emitInstr (I32Load offset) = "i32.load offset=" ++ show offset
emitInstr (I32Store offset) = "i32.store offset=" ++ show offset
emitInstr (I64Load offset) = "i64.load offset=" ++ show offset
emitInstr (I64Store offset) = "i64.store offset=" ++ show offset
emitInstr (I32Load8U offset) = "i32.load8_u offset=" ++ show offset
emitInstr (I32Load16U offset) = "i32.load16_u offset=" ++ show offset
emitInstr (I32Store8 offset) = "i32.store8 offset=" ++ show offset

-- i64 operations
emitInstr (I64Const n) = "i64.const " ++ show n
emitInstr I64Add = "i64.add"
emitInstr I64Sub = "i64.sub"
emitInstr I64Mul = "i64.mul"
emitInstr I64DivU = "i64.div_u"
emitInstr I64DivS = "i64.div_s"
emitInstr I64RemU = "i64.rem_u"
emitInstr I64RemS = "i64.rem_s"
emitInstr I64And = "i64.and"
emitInstr I64Or = "i64.or"
emitInstr I64Shl = "i64.shl"
emitInstr I64ShrU = "i64.shr_u"
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

-- f64 operations
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

-- Control flow
emitInstr (Call name) = "call $" ++ name
emitInstr (CallIndirect typeName) = "call_indirect (type $" ++ typeName ++ ")"
emitInstr (If resultTy thenInstrs elseInstrs) =
  unlines $
    ["if (result " ++ emitValType resultTy ++ ")"]
      ++ map (("  " ++) . emitInstr) thenInstrs
      ++ ["else"]
      ++ map (("  " ++) . emitInstr) elseInstrs
      ++ ["end"]
emitInstr (IfVoid thenInstrs elseInstrs) =
  unlines $
    ["if"]
      ++ map (("  " ++) . emitInstr) thenInstrs
      ++ (if null elseInstrs then [] else ["else"] ++ map (("  " ++) . emitInstr) elseInstrs)
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
emitInstr (BrTable labels dflt) =
  "br_table " ++ unwords (map ("$" ++) labels) ++ " $" ++ dflt
emitInstr Return = "return"
emitInstr Unreachable = "unreachable"
emitInstr Drop = "drop"
emitInstr (Comment s) = ";; " ++ s
emitInstr Nop = "nop"

-- | Emit a global variable definition
emitGlobal :: WatGlobal -> String
emitGlobal g =
  "  (global $" ++ globalName g ++ " " ++ typeDecl ++ " (" ++ emitValType (globalType g) ++ ".const " ++ show (globalInit g) ++ "))"
  where
    typeDecl = if globalMutable g
               then "(mut " ++ emitValType (globalType g) ++ ")"
               else emitValType (globalType g)

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
      ++ typeDecls
      ++ memoryDecl
      ++ tableDecl
      ++ map emitGlobal (moduleGlobals m)
      ++ map emitFunction (moduleFunctions m)
      ++ elemDecl
      ++ map emitExport (moduleExports m)
      ++ memoryExportDecl
      ++ [")"]
  where
    -- Function type declarations (for call_indirect)
    typeDecls = map emitFuncType (moduleFuncTypes m)

    emitFuncType ft =
      let params = if null (funcTypeParams ft)
                     then ""
                     else " (param " ++ unwords (map emitValType (funcTypeParams ft)) ++ ")"
          results = if null (funcTypeResults ft)
                      then ""
                      else " (result " ++ unwords (map emitValType (funcTypeResults ft)) ++ ")"
      in "  (type $" ++ funcTypeName ft ++ " (func" ++ params ++ results ++ "))"

    memoryDecl = case moduleMemory m of
      Nothing -> []
      Just pages -> ["  (memory " ++ show pages ++ ")"]

    -- Function table (for call_indirect)
    tableDecl
      | null (moduleTableFuncs m) = []
      | otherwise = ["  (table " ++ show (length (moduleTableFuncs m)) ++ " funcref)"]

    -- Element section populates the table with function references
    elemDecl
      | null (moduleTableFuncs m) = []
      | otherwise =
          ["  (elem (i32.const 0) " ++ unwords (map ("$" ++) (moduleTableFuncs m)) ++ ")"]

    memoryExportDecl = case moduleMemoryExport m of
      Nothing -> []
      Just name -> ["  (export \"" ++ name ++ "\" (memory 0))"]

    emitExport name =
      "  (export \"" ++ name ++ "\" (func $" ++ name ++ "))"
