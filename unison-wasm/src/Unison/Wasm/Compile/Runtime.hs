-- | Runtime support functions for WASM compilation.
--
-- This module defines the runtime infrastructure that gets included
-- in every compiled WASM module:
--
-- * Heap allocator (@__alloc@)
-- * PAp allocator (@__alloc_pap@)
-- * Apply functions (@__apply1@, @__apply2@, etc.)
-- * Runtime globals (@heap_ptr@)
-- * Function type signatures for @call_indirect@
--
-- All functions use ABI constants from 'Unison.Wasm.ABI'.
module Unison.Wasm.Compile.Runtime
  ( -- * Runtime Components
    runtimeFunctions,
    runtimeGlobals,
    runtimeFuncTypes,

    -- * Individual Functions (for testing)
    allocFunction,
    allocPApFunction,
    mkApplyFunction,

    -- * Constants
    heapStartAddress,
    maxSupportedArity,

    -- * Helpers
    arityTypeName,
  )
where

import Data.Word (Word32)
import Unison.Wasm.ABI qualified as ABI
import Unison.Wasm.Emit
  ( WatFuncType (..),
    WatFunction (..),
    WatGlobal (..),
    WatInstr (..),
    WatValType (..),
  )

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

-- | Initial heap pointer (after reserved area for runtime data)
-- Heap starts at 0x4000 (16KB) to leave room for runtime structures
heapStartAddress :: Word32
heapStartAddress = fromIntegral ABI.memoryHeapStart

-- | Maximum function arity we support for call_indirect
maxSupportedArity :: Int
maxSupportedArity = 6

--------------------------------------------------------------------------------
-- Runtime Globals
--------------------------------------------------------------------------------

-- | Heap pointer global variable
heapPtrGlobal :: WatGlobal
heapPtrGlobal =
  WatGlobal
    { globalName = "heap_ptr",
      globalType = I32,
      globalMutable = True,
      globalInit = fromIntegral heapStartAddress
    }

-- | All runtime globals
runtimeGlobals :: [WatGlobal]
runtimeGlobals = [heapPtrGlobal]

--------------------------------------------------------------------------------
-- Bump Allocator
--------------------------------------------------------------------------------

-- | Bump allocator function: @__alloc(size: i32) -> i32@
--
-- Allocates memory from the heap with 8-byte alignment.
allocFunction :: WatFunction
allocFunction =
  WatFunction
    { funcName = "__alloc",
      funcParams = [("size", I32)],
      funcLocals = [("ptr", I32)],
      funcResults = [I32],
      funcBody =
        [ Comment "Bump allocator: ptr = heap_ptr; heap_ptr += align8(size); return ptr",
          -- ptr = heap_ptr
          GlobalGet "heap_ptr",
          LocalSet "ptr",
          -- Align size to 8 bytes: size = (size + 7) & ~7
          LocalGet "size",
          I32Const 7,
          I32Add,
          I32Const 0xFFFFFFF8, -- ~7 as u32
          I32And,
          -- heap_ptr = heap_ptr + aligned_size
          GlobalGet "heap_ptr",
          I32Add,
          GlobalSet "heap_ptr",
          -- Return ptr
          LocalGet "ptr"
        ]
    }

--------------------------------------------------------------------------------
-- PAp Allocator
--------------------------------------------------------------------------------

-- | PAp allocation helper: @__alloc_pap(func_id, arity, count) -> i32@
--
-- Allocates a PAp object with space for captured arguments.
-- The caller must fill in the captured argument slots.
allocPApFunction :: WatFunction
allocPApFunction =
  WatFunction
    { funcName = "__alloc_pap",
      funcParams = [("func_id", I32), ("expected_arity", I32), ("captured_count", I32)],
      funcLocals = [("ptr", I32), ("size", I32)],
      funcResults = [I32],
      funcBody =
        [ Comment "Allocate PAp: header + func_id + arity info + captured slots",
          -- size = pApBaseSize + captured_count * typedSlotSize
          I32Const (fromIntegral ABI.pApBaseSize),
          LocalGet "captured_count",
          I32Const (fromIntegral ABI.typedSlotSize),
          I32Mul,
          I32Add,
          LocalSet "size",
          -- ptr = __alloc(size)
          LocalGet "size",
          Call "__alloc",
          LocalSet "ptr",
          -- Write header: ObjTag (12 bits) | Size (20 bits)
          -- Header = (OBJ_PAP << 20) | captured_count
          LocalGet "ptr",
          I32Const (fromIntegral (ABI.objTagToWord16 ABI.objPAp)),
          I32Const 20,
          I32Shl,
          LocalGet "captured_count",
          I32Or,
          I32Store 0,
          -- Write func_id at pApFuncRefOffset
          LocalGet "ptr",
          LocalGet "func_id",
          I32Store (fromIntegral ABI.pApFuncRefOffset),
          -- Write expected_arity at pApExpectedArityOffset
          LocalGet "ptr",
          LocalGet "expected_arity",
          I32Store (fromIntegral ABI.pApExpectedArityOffset),
          -- Write captured_count at pApCapturedCountOffset
          LocalGet "ptr",
          LocalGet "captured_count",
          I32Store (fromIntegral ABI.pApCapturedCountOffset),
          -- Return pointer
          LocalGet "ptr"
        ]
    }

--------------------------------------------------------------------------------
-- Apply Functions (Generated)
--------------------------------------------------------------------------------

-- | Generate an apply function for a given number of new arguments.
--
-- @__applyN(pap_ptr: i32, arg1: i64, ..., argN: i64) -> i64@
--
-- Reads the PAp, dispatches based on captured count to call the
-- underlying function with all arguments.
mkApplyFunction :: Int -> WatFunction
mkApplyFunction numNewArgs =
  WatFunction
    { funcName = "__apply" ++ show numNewArgs,
      funcParams = [("pap_ptr", I32)] ++ argParams,
      funcLocals = [("func_idx", I32), ("captured", I32)],
      funcResults = [I64],
      funcBody = applyBody
    }
  where
    argParams = [("arg" ++ show i, I64) | i <- [1 .. numNewArgs]]

    applyBody =
      [ Comment $ "Apply " ++ show numNewArgs ++ " arg(s) to PAp",
        -- Read func_idx from PAp
        LocalGet "pap_ptr",
        I32Load (fromIntegral ABI.pApFuncRefOffset),
        LocalSet "func_idx",
        -- Read captured_count
        LocalGet "pap_ptr",
        I32Load16U (fromIntegral ABI.pApCapturedCountOffset),
        LocalSet "captured"
      ]
        ++ dispatchOnCaptured

    -- Generate dispatch code based on captured count
    -- We need to handle captured = 0, 1, 2, ... up to (maxArity - numNewArgs)
    dispatchOnCaptured :: [WatInstr]
    dispatchOnCaptured = buildDispatchChain 0

    -- Build a chain of if-else for each possible captured count
    buildDispatchChain :: Int -> [WatInstr]
    buildDispatchChain capturedCount
      | capturedCount + numNewArgs > maxSupportedArity =
          -- Default case: trap (shouldn't happen with valid PAps)
          [Unreachable]
      | capturedCount + numNewArgs == maxSupportedArity =
          -- Last case: no more branching needed
          genCallCase capturedCount
      | otherwise =
          -- Check if captured == capturedCount, else check next
          [ LocalGet "captured",
            I32Const (fromIntegral capturedCount),
            I32Eq,
            If I64
              (genCallCase capturedCount)
              (buildDispatchChain (capturedCount + 1))
          ]

    -- Generate code for calling with a specific captured count
    genCallCase :: Int -> [WatInstr]
    genCallCase capturedCount =
      let totalArity = capturedCount + numNewArgs
          -- Load all captured args first
          loadCaptured = concatMap loadCapturedAt [0 .. capturedCount - 1]
          -- Then push new args
          pushNewArgs = [LocalGet ("arg" ++ show i) | i <- [1 .. numNewArgs]]
       in loadCaptured
            ++ pushNewArgs
            ++ [ LocalGet "func_idx",
                 CallIndirect (arityTypeName totalArity)
               ]

    -- Load captured arg at index
    loadCapturedAt :: Int -> [WatInstr]
    loadCapturedAt i =
      let offset =
            fromIntegral ABI.pApArgsOffset
              + fromIntegral i * fromIntegral ABI.typedSlotSize
              + 8 -- Skip TypeTag to get Payload64
       in [LocalGet "pap_ptr", I64Load offset]

--------------------------------------------------------------------------------
-- Function Types for call_indirect
--------------------------------------------------------------------------------

-- | Function type name for a given arity
arityTypeName :: Int -> String
arityTypeName n = "arity_" ++ show n

-- | Generate function type for a given arity
mkFuncType :: Int -> WatFuncType
mkFuncType arity =
  WatFuncType
    { funcTypeName = arityTypeName arity,
      funcTypeParams = replicate arity I64,
      funcTypeResults = [I64]
    }

-- | All runtime function types (arity 1 through maxSupportedArity)
runtimeFuncTypes :: [WatFuncType]
runtimeFuncTypes = map mkFuncType [1 .. maxSupportedArity]

--------------------------------------------------------------------------------
-- Aggregated Runtime
--------------------------------------------------------------------------------

-- | All runtime helper functions
runtimeFunctions :: [WatFunction]
runtimeFunctions =
  [ allocFunction,
    allocPApFunction
  ]
    ++ map mkApplyFunction [1 .. 3] -- Generate __apply1, __apply2, __apply3
