-- | Primitive instruction builders for WASM compilation.
--
-- This module provides helper functions for common instruction patterns:
-- * Memory access (load/store at offsets)
-- * TypedSlot manipulation (read/write tagged values)
-- * PAp field access
-- * Loop generation for copying slots
--
-- All offsets use constants from 'Unison.Wasm.ABI' to avoid magic numbers.
module Unison.Wasm.Compile.Primitives
  ( -- * Memory Access Helpers
    loadI32,
    loadI64,
    loadI32At,
    loadI64At,
    storeI32,
    storeI64,
    storeI32At,
    storeI64At,

    -- * TypedSlot Helpers
    loadSlotPayload,
    loadSlotTag,
    storeSlot,
    slotPayloadOffset,

    -- * PAp Field Access
    loadPApFuncId,
    loadPApArity,
    loadPApCapturedCount,
    loadPApCapturedArg,
    storePApCapturedArg,

    -- * Pointer Helpers
    wrapI64ToPtr,
    extendPtrToI64,

    -- * Loop Generation
    copySlotLoop,
    copyNSlots,

    -- * Debug Helpers
    comment,
  )
where

import Data.Word (Word32)
import Unison.Wasm.ABI qualified as ABI
import Unison.Wasm.Emit (WatInstr (..))

--------------------------------------------------------------------------------
-- Memory Access Helpers
--------------------------------------------------------------------------------

-- | Load i32 from address on stack with offset
loadI32 :: Word32 -> WatInstr
loadI32 = I32Load

-- | Load i64 from address on stack with offset
loadI64 :: Word32 -> WatInstr
loadI64 = I64Load

-- | Load i32 from a local variable with offset
loadI32At :: String -> Word32 -> [WatInstr]
loadI32At localName offset =
  [LocalGet localName, I32Load offset]

-- | Load i64 from a local variable with offset
loadI64At :: String -> Word32 -> [WatInstr]
loadI64At localName offset =
  [LocalGet localName, I64Load offset]

-- | Store i32 to address on stack with offset
storeI32 :: Word32 -> WatInstr
storeI32 = I32Store

-- | Store i64 to address on stack with offset
storeI64 :: Word32 -> WatInstr
storeI64 = I64Store

-- | Store i32 at local pointer + offset. Stack: [value]
storeI32At :: String -> Word32 -> [WatInstr] -> [WatInstr]
storeI32At localName offset valueInstrs =
  [LocalGet localName] ++ valueInstrs ++ [I32Store offset]

-- | Store i64 at local pointer + offset. Stack: [value]
storeI64At :: String -> Word32 -> [WatInstr] -> [WatInstr]
storeI64At localName offset valueInstrs =
  [LocalGet localName] ++ valueInstrs ++ [I64Store offset]

--------------------------------------------------------------------------------
-- TypedSlot Helpers
--------------------------------------------------------------------------------

-- | Calculate the payload offset within a slot at given index
-- Payload is at slotBase + 8 (after TypeTag)
slotPayloadOffset :: Word32 -> Word32 -> Word32
slotPayloadOffset baseOffset slotIndex =
  baseOffset + slotIndex * fromIntegral ABI.typedSlotSize + 8

-- | Load the Payload64 from a TypedSlot at given index
-- Uses ABI.typedSlotSize (16) for slot stride
loadSlotPayload :: String -> Word32 -> Word32 -> [WatInstr]
loadSlotPayload ptrLocal baseOffset slotIndex =
  [LocalGet ptrLocal, I64Load (slotPayloadOffset baseOffset slotIndex)]

-- | Load the TypeTag from a TypedSlot at given index
loadSlotTag :: String -> Word32 -> Word32 -> [WatInstr]
loadSlotTag ptrLocal baseOffset slotIndex =
  let tagOffset = baseOffset + slotIndex * fromIntegral ABI.typedSlotSize
   in [LocalGet ptrLocal, I32Load8U tagOffset]

-- | Store a complete TypedSlot (tag + payload)
storeSlot ::
  String ->      -- ^ Pointer local
  Word32 ->      -- ^ Base offset
  Word32 ->      -- ^ Slot index
  Word32 ->      -- ^ TypeTag value
  [WatInstr] ->  -- ^ Instructions producing the payload (i64)
  [WatInstr]
storeSlot ptrLocal baseOffset slotIndex typeTag payloadInstrs =
  let slotOffset = baseOffset + slotIndex * fromIntegral ABI.typedSlotSize
      tagOffset = slotOffset
      payloadOffset = slotOffset + 8
   in -- Store TypeTag
      [LocalGet ptrLocal, I32Const typeTag, I32Store tagOffset]
        ++
        -- Store Payload64
        [LocalGet ptrLocal] ++ payloadInstrs ++ [I64Store payloadOffset]

--------------------------------------------------------------------------------
-- PAp Field Access
--------------------------------------------------------------------------------

-- | Load PAp func_id (table index) from pointer
loadPApFuncId :: String -> [WatInstr]
loadPApFuncId ptrLocal =
  loadI32At ptrLocal (fromIntegral ABI.pApFuncRefOffset)

-- | Load PAp expected arity from pointer
loadPApArity :: String -> [WatInstr]
loadPApArity ptrLocal =
  [LocalGet ptrLocal, I32Load16U (fromIntegral ABI.pApExpectedArityOffset)]

-- | Load PAp captured count from pointer
loadPApCapturedCount :: String -> [WatInstr]
loadPApCapturedCount ptrLocal =
  [LocalGet ptrLocal, I32Load16U (fromIntegral ABI.pApCapturedCountOffset)]

-- | Load PAp captured argument at index (the Payload64 only)
loadPApCapturedArg :: String -> Word32 -> [WatInstr]
loadPApCapturedArg ptrLocal argIndex =
  loadSlotPayload ptrLocal (fromIntegral ABI.pApArgsOffset) argIndex

-- | Store PAp captured argument at index
storePApCapturedArg ::
  String ->      -- ^ PAp pointer local
  Word32 ->      -- ^ Argument index
  Word32 ->      -- ^ TypeTag value
  [WatInstr] ->  -- ^ Instructions producing the payload (i64)
  [WatInstr]
storePApCapturedArg ptrLocal argIndex typeTag payloadInstrs =
  storeSlot ptrLocal (fromIntegral ABI.pApArgsOffset) argIndex typeTag payloadInstrs

--------------------------------------------------------------------------------
-- Pointer Helpers
--------------------------------------------------------------------------------

-- | Extract i32 pointer from i64 boxed value (low 32 bits)
wrapI64ToPtr :: [WatInstr]
wrapI64ToPtr = [I32WrapI64]

-- | Extend i32 pointer to i64 boxed value
extendPtrToI64 :: [WatInstr]
extendPtrToI64 = [I64ExtendI32U]

--------------------------------------------------------------------------------
-- Loop Generation
--------------------------------------------------------------------------------

-- | Generate a loop that copies N TypedSlot payloads from src to dst.
--
-- This uses a counter local and structured loop control instead of
-- deeply nested if-else chains.
--
-- Requires: counter local already declared in function locals
copySlotLoop ::
  String ->   -- ^ Source pointer local
  String ->   -- ^ Destination pointer local
  String ->   -- ^ Counter local (i32)
  Word32 ->   -- ^ Base offset in source
  Word32 ->   -- ^ Base offset in destination
  String ->   -- ^ Max count local (i32) - how many slots to copy
  [WatInstr]
copySlotLoop srcPtr dstPtr counterLocal srcBase dstBase maxCountLocal =
  [ -- Initialize counter to 0
    I32Const 0,
    LocalSet counterLocal,
    -- Loop
    Block "copy_done"
      [ Loop "copy_loop"
          [ -- Check if counter >= maxCount
            LocalGet counterLocal,
            LocalGet maxCountLocal,
            I32GeU,
            BrIf "copy_done",
            -- Copy one slot: dst[counter] = src[counter]
            -- Calculate source offset: srcBase + counter * 16 + 8
            LocalGet dstPtr,
            LocalGet srcPtr,
            -- Load from src: srcBase + counter * slotSize + 8 (payload offset)
            LocalGet counterLocal,
            I32Const (fromIntegral ABI.typedSlotSize),
            I32Mul,
            I32Const (srcBase + 8),  -- Add base + payload offset
            I32Add,
            I32Add,  -- srcPtr + offset
            I64Load 0,
            -- Store to dst at same offset pattern
            LocalGet counterLocal,
            I32Const (fromIntegral ABI.typedSlotSize),
            I32Mul,
            I32Const (dstBase + 8),
            I32Add,
            I64Store 0,
            -- Increment counter
            LocalGet counterLocal,
            I32Const 1,
            I32Add,
            LocalSet counterLocal,
            -- Continue loop
            Br "copy_loop"
          ]
      ]
  ]

-- | Copy exactly N slots using unrolled code (for small N).
-- More efficient than loop for N <= 4.
copyNSlots ::
  String ->   -- ^ Source pointer local
  String ->   -- ^ Destination pointer local
  Word32 ->   -- ^ Source base offset
  Word32 ->   -- ^ Destination base offset
  Int ->      -- ^ Number of slots to copy
  [WatInstr]
copyNSlots srcPtr dstPtr srcBase dstBase n =
  concatMap copyOne [0 .. fromIntegral n - 1]
  where
    copyOne :: Word32 -> [WatInstr]
    copyOne i =
      let srcOffset = slotPayloadOffset srcBase i
          dstOffset = slotPayloadOffset dstBase i
       in [ LocalGet dstPtr,
            LocalGet srcPtr,
            I64Load srcOffset,
            I64Store dstOffset
          ]

--------------------------------------------------------------------------------
-- Debug Helpers
--------------------------------------------------------------------------------

-- | Add a comment instruction for debugging
comment :: String -> WatInstr
comment = Comment
