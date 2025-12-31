-- | Builtin and primitive operation compilation.
--
-- This module maps Unison builtins and primitive operations to WASM instructions:
-- * POp → single WASM instruction (e.g., ADDN → i64.add)
-- * Builtin names → instruction sequences (e.g., "Nat.+" → [i64.add])
-- * Float operations with necessary type conversions
module Unison.Wasm.Compile.Builtins
  ( -- * Primitive Operations
    compilePrimOp,
    PrimOpError (..),

    -- * Builtin Mapping
    builtinToPrimOp,

    -- * Float Helpers
    floatBinOp,
    floatCmpOp,
  )
where

import Data.Text (Text)
import Unison.Runtime.ANF.POp (POp (..))
import Unison.Wasm.Emit (WatInstr (..))

-- | Error type for primitive operation compilation
data PrimOpError
  = UnsupportedPrimOp POp
  deriving (Eq, Show)

-- | Compile a primitive operation to a WASM instruction
compilePrimOp :: POp -> Int -> Either PrimOpError WatInstr
-- Nat operations
compilePrimOp ADDN 2 = pure I64Add
compilePrimOp SUBN 2 = pure I64Sub
compilePrimOp MULN 2 = pure I64Mul
compilePrimOp DIVN 2 = pure I64DivU
compilePrimOp MODN 2 = pure I64RemU
compilePrimOp INCN 1 = pure I64Add -- Caller pushes 1; we just emit add
compilePrimOp DECN 1 = pure I64Sub -- Caller pushes 1; we just emit sub
compilePrimOp LEQN 2 = pure I64LeU
compilePrimOp LESN 2 = pure I64LtU
compilePrimOp EQLN 2 = pure I64Eq
compilePrimOp NEQN 2 = pure I64Ne
-- Int operations
compilePrimOp ADDI 2 = pure I64Add
compilePrimOp SUBI 2 = pure I64Sub
compilePrimOp MULI 2 = pure I64Mul
compilePrimOp DIVI 2 = pure I64DivS
compilePrimOp MODI 2 = pure I64RemS
compilePrimOp LEQI 2 = pure I64LeS
compilePrimOp LESI 2 = pure I64LtS
compilePrimOp EQLI 2 = pure I64Eq
compilePrimOp NEQI 2 = pure I64Ne
compilePrimOp NEGI 1 = pure I64Sub -- Caller pushes 0; we emit sub for (0 - x)
-- Float operations
compilePrimOp ADDF 2 = pure F64Add
compilePrimOp SUBF 2 = pure F64Sub
compilePrimOp MULF 2 = pure F64Mul
compilePrimOp DIVF 2 = pure F64Div
compilePrimOp LEQF 2 = pure F64Le
compilePrimOp LESF 2 = pure F64Lt
compilePrimOp EQLF 2 = pure F64Eq
-- Debug operations (FFI calls)
compilePrimOp TRCE 2 = pure $ Call "Debug_trace" -- (Text, a) -> ()
compilePrimOp PRNT 1 = pure $ Call "Debug_watch" -- Text -> Text
-- Unsupported operations
compilePrimOp op _n = Left $ UnsupportedPrimOp op

--------------------------------------------------------------------------------
-- Builtin Reference Mapping
--------------------------------------------------------------------------------

-- | Map builtin reference names to WASM instructions
-- This handles the case where parsed Unison code calls builtins via FComb
-- rather than using TPrm directly.
--
-- Note: Comparison ops return i32 in WASM, so we extend to i64.
-- Float ops produce f64, so we reinterpret to i64 for the return value.
builtinToPrimOp :: Text -> Int -> Maybe [WatInstr]
-- Nat operations (the ## prefix is stripped by the parser)
builtinToPrimOp "Nat.+" 2 = Just [I64Add]
builtinToPrimOp "Nat.-" 2 = Just [I64Sub] -- Also handle Nat.- alias
builtinToPrimOp "Nat.sub" 2 = Just [I64Sub]
builtinToPrimOp "Nat.drop" 2 = Just [I64Sub] -- Saturating sub (TODO: should clamp to 0)
builtinToPrimOp "Nat.*" 2 = Just [I64Mul]
builtinToPrimOp "Nat./" 2 = Just [I64DivU]
builtinToPrimOp "Nat.mod" 2 = Just [I64RemU]
builtinToPrimOp "Nat.<=" 2 = Just [I64LeU, I64ExtendI32U] -- Comparison returns i32, extend to i64
builtinToPrimOp "Nat.<" 2 = Just [I64LtU, I64ExtendI32U]
builtinToPrimOp "Nat.>=" 2 = Just [I64GeU, I64ExtendI32U]
builtinToPrimOp "Nat.>" 2 = Just [I64GtU, I64ExtendI32U]
builtinToPrimOp "Nat.==" 2 = Just [I64Eq, I64ExtendI32U]
builtinToPrimOp "Universal.==" 2 = Just [I64Eq, I64ExtendI32U]
-- Int operations
builtinToPrimOp "Int.+" 2 = Just [I64Add]
builtinToPrimOp "Int.-" 2 = Just [I64Sub]
builtinToPrimOp "Int.*" 2 = Just [I64Mul]
builtinToPrimOp "Int./" 2 = Just [I64DivS]
builtinToPrimOp "Int.mod" 2 = Just [I64RemS]
builtinToPrimOp "Int.<=" 2 = Just [I64LeS, I64ExtendI32U]
builtinToPrimOp "Int.<" 2 = Just [I64LtS, I64ExtendI32U]
builtinToPrimOp "Int.==" 2 = Just [I64Eq, I64ExtendI32U]
-- Float operations
-- Operands are stored as i64 (reinterpreted), so we convert back to f64, do the op, then convert result to i64
-- Stack before: [i64_a, i64_b]
-- We need: f64.reinterpret_i64 on each operand before the float op
-- But we can't insert between operands with this approach, so we use a different strategy:
-- The caller (compileANormal for FComb) handles pushing operands as i64.
-- Float ops need to convert both operands. We handle this by emitting extra instructions.
builtinToPrimOp "Float.+" 2 = Just $ floatBinOp F64Add
builtinToPrimOp "Float.-" 2 = Just $ floatBinOp F64Sub
builtinToPrimOp "Float.*" 2 = Just $ floatBinOp F64Mul
builtinToPrimOp "Float./" 2 = Just $ floatBinOp F64Div
builtinToPrimOp "Float.<=" 2 = Just $ floatCmpOp F64Le
builtinToPrimOp "Float.<" 2 = Just $ floatCmpOp F64Lt
builtinToPrimOp "Float.==" 2 = Just $ floatCmpOp F64Eq
-- Debug operations (FFI calls)
builtinToPrimOp "Debug.trace" 2 = Just [Call "Debug_trace"]
builtinToPrimOp "Debug.watch" 2 = Just [Call "Debug_watch"]
-- Unknown builtin
builtinToPrimOp _ _ = Nothing

-- | Generate instructions for a float binary operation.
-- Stack before: [i64_a, i64_b]  (floats stored as reinterpreted i64)
-- We need to convert both to f64, do the op, then convert result back to i64.
-- Uses a temp local to handle the stack manipulation.
floatBinOp :: WatInstr -> [WatInstr]
floatBinOp op =
  [ -- Stack: [i64_a, i64_b]
    -- Save b to temp, convert a, reload b as f64
    LocalSet "__float_temp", -- Stack: [i64_a], temp = i64_b
    F64ReinterpretI64, -- Stack: [f64_a]
    LocalGet "__float_temp", -- Stack: [f64_a, i64_b]
    F64ReinterpretI64, -- Stack: [f64_a, f64_b]
    op, -- Stack: [f64_result]
    I64ReinterpretF64 -- Stack: [i64_result]
  ]

-- | Generate instructions for a float comparison operation.
-- Same as floatBinOp but result is i32 (extended to i64).
floatCmpOp :: WatInstr -> [WatInstr]
floatCmpOp op =
  [ LocalSet "__float_temp",
    F64ReinterpretI64,
    LocalGet "__float_temp",
    F64ReinterpretI64,
    op, -- Stack: [i32_result]
    I64ExtendI32U -- Stack: [i64_result]
  ]

