-- | Runtime support functions for WASM compilation.
--
-- This module defines the runtime infrastructure that gets included
-- in every compiled WASM module:
--
-- * Heap allocator (@__alloc@)
-- * PAp allocator (@__alloc_pap@)
-- * Data allocators (@__alloc_data1@, @__alloc_data2@, @__alloc_datag@)
-- * Apply functions (@__apply1@, @__apply2@, etc.)
-- * Runtime globals (@heap_ptr@, @k_ptr@)
-- * Function type signatures for @call_indirect@
--
-- All functions use ABI constants from 'Unison.Wasm.ABI'.
module Unison.Wasm.Compile.Runtime
  ( -- * Runtime Components
    runtimeFunctions,
    runtimeGlobals,
    runtimeFuncTypes,
    runtimeExports,

    -- * Individual Functions (for testing)
    allocFunction,
    allocPApFunction,
    allocData1Function,
    allocData2Function,
    allocDataGFunction,
    allocCapturedFunction,
    mkApplyFunction,
    allocAsyncContFunction,
    resumeFunction,
    resumeWithErrorFunction,
    allocData1RawFunction,

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

-- | Continuation stack pointer (K)
-- Points to the current top of the continuation stack.
-- 0 = KE (empty continuation)
kPtrGlobal :: WatGlobal
kPtrGlobal =
  WatGlobal
    { globalName = "k_ptr",
      globalType = I32,
      globalMutable = True,
      globalInit = 0 -- KE = empty continuation
    }

-- | Dynamic environment pointer (DEnv)
-- Points to the current handler environment.
-- 0 = empty environment
denvPtrGlobal :: WatGlobal
denvPtrGlobal =
  WatGlobal
    { globalName = "denv_ptr",
      globalType = I32,
      globalMutable = True,
      globalInit = 0
    }

-- | Async continuation ID global
-- Stores the current continuation ID for yield/resume.
-- 0 = no async in progress
asyncContIdGlobal :: WatGlobal
asyncContIdGlobal =
  WatGlobal
    { globalName = "async_cont_id",
      globalType = I64,
      globalMutable = True,
      globalInit = 0
    }

-- | Async continuation pointer global
-- Stores pointer to the OBJ_ASYNC_CONT object for the current async operation.
-- 0 = no async in progress
asyncContPtrGlobal :: WatGlobal
asyncContPtrGlobal =
  WatGlobal
    { globalName = "async_cont_ptr",
      globalType = I32,
      globalMutable = True,
      globalInit = 0
    }

-- | Async resuming flag
-- 1 = we're entering a function via __resume, 0 = normal entry
asyncResumingGlobal :: WatGlobal
asyncResumingGlobal =
  WatGlobal
    { globalName = "__async_resuming",
      globalType = I32,
      globalMutable = True,
      globalInit = 0
    }

-- | Async resume label
-- Which yield point to jump to when resuming (index into br_table)
asyncResumeLabelGlobal :: WatGlobal
asyncResumeLabelGlobal =
  WatGlobal
    { globalName = "__async_resume_label",
      globalType = I32,
      globalMutable = True,
      globalInit = 0
    }

-- | Async resume value
-- The value passed to __resume, to be used as FFI result
asyncResumeValueGlobal :: WatGlobal
asyncResumeValueGlobal =
  WatGlobal
    { globalName = "__async_resume_value",
      globalType = I64,
      globalMutable = True,
      globalInit = 0
    }

-- | All runtime globals
runtimeGlobals :: [WatGlobal]
runtimeGlobals =
  [ heapPtrGlobal,
    kPtrGlobal,
    denvPtrGlobal,
    asyncContIdGlobal,
    asyncContPtrGlobal,
    asyncResumingGlobal,
    asyncResumeLabelGlobal,
    asyncResumeValueGlobal
  ]

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
-- Data Type Allocators
--------------------------------------------------------------------------------

-- | Data1 allocation: @__alloc_data1(type_ref, ctor_id, field0) -> i32@
--
-- Allocates a Data1 object (one field).
allocData1Function :: WatFunction
allocData1Function =
  WatFunction
    { funcName = "__alloc_data1",
      funcParams = [("type_ref", I32), ("ctor_id", I32), ("field0_tag", I32), ("field0_val", I64)],
      funcLocals = [("ptr", I32)],
      funcResults = [I32],
      funcBody =
        [ Comment "Allocate Data1: header + type/ctor + 1 field",
          -- Allocate 32 bytes (data1Size)
          I32Const (fromIntegral ABI.data1Size),
          Call "__alloc",
          LocalSet "ptr",
          -- Write header: (OBJ_DATA1 << 20) | 1
          LocalGet "ptr",
          I32Const (fromIntegral (ABI.objTagToWord16 ABI.objData1)),
          I32Const 20,
          I32Shl,
          I32Const 1, -- Size = 1 field
          I32Or,
          I32Store 0,
          -- Write type_ref at offset 8
          LocalGet "ptr",
          LocalGet "type_ref",
          I32Store (fromIntegral ABI.data1TypeRefOffset),
          -- Write ctor_id at offset 12
          LocalGet "ptr",
          LocalGet "ctor_id",
          I32Store (fromIntegral ABI.data1CtorIdOffset),
          -- Write field0 TypeTag at offset 16
          LocalGet "ptr",
          LocalGet "field0_tag",
          I32Store (fromIntegral ABI.data1Field0Offset),
          -- Write field0 Payload64 at offset 24 (16 + 8)
          LocalGet "ptr",
          LocalGet "field0_val",
          I64Store (fromIntegral ABI.data1Field0Offset + 8),
          -- Return pointer
          LocalGet "ptr"
        ]
    }

-- | Data2 allocation: @__alloc_data2(type_ref, ctor_id, f0_tag, f0_val, f1_tag, f1_val) -> i32@
--
-- Allocates a Data2 object (two fields).
allocData2Function :: WatFunction
allocData2Function =
  WatFunction
    { funcName = "__alloc_data2",
      funcParams =
        [ ("type_ref", I32),
          ("ctor_id", I32),
          ("field0_tag", I32),
          ("field0_val", I64),
          ("field1_tag", I32),
          ("field1_val", I64)
        ],
      funcLocals = [("ptr", I32)],
      funcResults = [I32],
      funcBody =
        [ Comment "Allocate Data2: header + type/ctor + 2 fields",
          -- Allocate 48 bytes (data2Size)
          I32Const (fromIntegral ABI.data2Size),
          Call "__alloc",
          LocalSet "ptr",
          -- Write header: (OBJ_DATA2 << 20) | 2
          LocalGet "ptr",
          I32Const (fromIntegral (ABI.objTagToWord16 ABI.objData2)),
          I32Const 20,
          I32Shl,
          I32Const 2, -- Size = 2 fields
          I32Or,
          I32Store 0,
          -- Write type_ref at offset 8
          LocalGet "ptr",
          LocalGet "type_ref",
          I32Store (fromIntegral ABI.data2TypeRefOffset),
          -- Write ctor_id at offset 12
          LocalGet "ptr",
          LocalGet "ctor_id",
          I32Store (fromIntegral ABI.data2CtorIdOffset),
          -- Write field0 TypedSlot at offset 16
          LocalGet "ptr",
          LocalGet "field0_tag",
          I32Store (fromIntegral ABI.data2Field0Offset),
          LocalGet "ptr",
          LocalGet "field0_val",
          I64Store (fromIntegral ABI.data2Field0Offset + 8),
          -- Write field1 TypedSlot at offset 32
          LocalGet "ptr",
          LocalGet "field1_tag",
          I32Store (fromIntegral ABI.data2Field1Offset),
          LocalGet "ptr",
          LocalGet "field1_val",
          I64Store (fromIntegral ABI.data2Field1Offset + 8),
          -- Return pointer
          LocalGet "ptr"
        ]
    }

-- | DataG allocation: @__alloc_datag(type_ref, ctor_id, arity) -> i32@
--
-- Allocates a DataG object (variable number of fields).
-- Caller must fill in the field slots.
allocDataGFunction :: WatFunction
allocDataGFunction =
  WatFunction
    { funcName = "__alloc_datag",
      funcParams = [("type_ref", I32), ("ctor_id", I32), ("arity", I32)],
      funcLocals = [("ptr", I32), ("size", I32)],
      funcResults = [I32],
      funcBody =
        [ Comment "Allocate DataG: header + type/ctor/arity + N fields",
          -- size = 16 + arity * 16
          I32Const 16,
          LocalGet "arity",
          I32Const (fromIntegral ABI.typedSlotSize),
          I32Mul,
          I32Add,
          LocalSet "size",
          -- Allocate
          LocalGet "size",
          Call "__alloc",
          LocalSet "ptr",
          -- Write header: (OBJ_DATAG << 20) | arity
          LocalGet "ptr",
          I32Const (fromIntegral (ABI.objTagToWord16 ABI.objDataG)),
          I32Const 20,
          I32Shl,
          LocalGet "arity",
          I32Or,
          I32Store 0,
          -- Write type_ref at offset 8
          LocalGet "ptr",
          LocalGet "type_ref",
          I32Store (fromIntegral ABI.dataGTypeRefOffset),
          -- Write ctor_id at offset 12
          LocalGet "ptr",
          LocalGet "ctor_id",
          I32Store (fromIntegral ABI.dataGCtorIdOffset),
          -- Write arity at offset 14
          LocalGet "ptr",
          LocalGet "arity",
          I32Store16 (fromIntegral ABI.dataGArityOffset),
          -- Return pointer (caller fills fields at offset 16+)
          LocalGet "ptr"
        ]
    }

--------------------------------------------------------------------------------
-- Captured Continuation Allocator
--------------------------------------------------------------------------------

-- | Captured allocation: @__alloc_captured(k_ptr, pending_args, slot_count) -> i32@
--
-- Allocates a Captured object for storing a captured continuation.
allocCapturedFunction :: WatFunction
allocCapturedFunction =
  WatFunction
    { funcName = "__alloc_captured",
      funcParams = [("k_ptr", I32), ("pending_args", I32), ("slot_count", I32)],
      funcLocals = [("ptr", I32), ("size", I32)],
      funcResults = [I32],
      funcBody =
        [ Comment "Allocate Captured: header + k_ptr + count + slots",
          -- size = capturedBaseSize + slot_count * typedSlotSize
          I32Const (fromIntegral ABI.capturedBaseSize),
          LocalGet "slot_count",
          I32Const (fromIntegral ABI.typedSlotSize),
          I32Mul,
          I32Add,
          LocalSet "size",
          -- Allocate
          LocalGet "size",
          Call "__alloc",
          LocalSet "ptr",
          -- Write header: (OBJ_CAPTURED << 20) | slot_count
          LocalGet "ptr",
          I32Const (fromIntegral (ABI.objTagToWord16 ABI.objCaptured)),
          I32Const 20,
          I32Shl,
          LocalGet "slot_count",
          I32Or,
          I32Store 0,
          -- Write k_ptr at offset 8
          LocalGet "ptr",
          LocalGet "k_ptr",
          I32Store (fromIntegral ABI.capturedKPtrOffset),
          -- Write pending_args at offset 12
          LocalGet "ptr",
          LocalGet "pending_args",
          I32Store (fromIntegral ABI.capturedCountOffset),
          -- Return pointer (caller fills slots at offset 16+)
          LocalGet "ptr"
        ]
    }

--------------------------------------------------------------------------------
-- Text Allocator
--------------------------------------------------------------------------------

-- | Text allocation: @__alloc_text(byte_len: i32) -> i32@
--
-- Allocates a Text object with space for the given number of UTF-8 bytes.
-- Layout:
--   bytes 0-7:   Header (ObjTag=TEXT, size)
--   bytes 8-11:  ByteLen (u32)
--   bytes 12-15: CharLen (u32, set to 0 - caller can update)
--   bytes 16+:   UTF-8 bytes
--
-- Caller is responsible for writing the actual bytes at ptr+16.
allocTextFunction :: WatFunction
allocTextFunction =
  WatFunction
    { funcName = "__alloc_text",
      funcParams = [("byte_len", I32)],
      funcLocals = [("ptr", I32), ("size", I32)],
      funcResults = [I32],
      funcBody =
        [ Comment "Allocate Text: header + bytelen + charlen + data",
          -- size = textBaseSize + align8(byte_len)
          I32Const (fromIntegral ABI.textBaseSize),
          LocalGet "byte_len",
          I32Const 7,
          I32Add,
          I32Const 0xFFFFFFF8, -- -8 as unsigned
          I32And,
          I32Add,
          LocalSet "size",
          -- Allocate
          LocalGet "size",
          Call "__alloc",
          LocalSet "ptr",
          -- Write header: (OBJ_TEXT << 48) | size
          LocalGet "ptr",
          I64Const (fromIntegral (ABI.objTagToWord16 ABI.objText)),
          I64Const 48,
          I64Shl,
          LocalGet "size",
          I64ExtendI32U,
          I64Or,
          I64Store 0,
          -- Write byte_len at offset 8
          LocalGet "ptr",
          LocalGet "byte_len",
          I32Store (fromIntegral ABI.textLengthOffset),
          -- Write char_len = 0 at offset 12 (placeholder)
          LocalGet "ptr",
          I32Const 0,
          I32Store 12,
          -- Return pointer (caller writes bytes at ptr+16)
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

-- | All runtime function types (arity 0 through maxSupportedArity)
-- Arity 0 is used for async resume (call_indirect with no params)
runtimeFuncTypes :: [WatFuncType]
runtimeFuncTypes = map mkFuncType [0 .. maxSupportedArity]

-- | Runtime exports (functions that JS can call)
-- These are exported in addition to the main entry function
runtimeExports :: [String]
runtimeExports = ["__resume", "__resume_with_error"]

--------------------------------------------------------------------------------
-- DEnv (Dynamic Handler Environment) Functions
--------------------------------------------------------------------------------

-- | Create empty DEnv: @__denv_new() -> i32@
allocDenvFunction :: WatFunction
allocDenvFunction =
  WatFunction
    { funcName = "__denv_new",
      funcParams = [],
      funcLocals = [("ptr", I32)],
      funcResults = [I32],
      funcBody =
        [ Comment "Create empty DEnv",
          -- Allocate space for count + max entries
          I32Const (fromIntegral $ ABI.denvSize ABI.denvMaxEntries),
          Call "__alloc",
          LocalSet "ptr",
          -- Initialize count to 0
          LocalGet "ptr",
          I32Const 0,
          I32Store (fromIntegral ABI.denvCountOffset),
          LocalGet "ptr"
        ]
    }

-- | DEnv lookup: @__denv_lookup(denv_ptr, key) -> i32@ (0 if not found)
-- Uses a simple linear search through entries.
denvLookupFunction :: WatFunction
denvLookupFunction =
  WatFunction
    { funcName = "__denv_lookup",
      funcParams = [("denv_ptr", I32), ("key", I32)],
      funcLocals = [("count", I32), ("i", I32), ("entry_ptr", I32), ("result", I32)],
      funcResults = [I32],
      funcBody =
        [ Comment "Lookup handler in DEnv by ability key",
          -- Initialize result to 0 (not found)
          I32Const 0,
          LocalSet "result",
          -- If denv_ptr is 0 (null), return 0
          LocalGet "denv_ptr",
          I32Eqz,
          IfVoid
            [] -- denv is null, result stays 0
            [ -- Load count
              LocalGet "denv_ptr",
              I32Load (fromIntegral ABI.denvCountOffset),
              LocalSet "count",
              -- Initialize i = 0
              I32Const 0,
              LocalSet "i",
              -- Loop through entries
              Block "lookup_done"
                [ Loop "lookup_loop"
                    [ -- if i >= count, break
                      LocalGet "i",
                      LocalGet "count",
                      I32GeU,
                      BrIf "lookup_done",
                      -- entry_ptr = denv_ptr + denvEntriesOffset + i * denvEntrySize
                      LocalGet "denv_ptr",
                      I32Const (fromIntegral ABI.denvEntriesOffset),
                      I32Add,
                      LocalGet "i",
                      I32Const (fromIntegral ABI.denvEntrySize),
                      I32Mul,
                      I32Add,
                      LocalSet "entry_ptr",
                      -- if entry_ptr.key == key, set result and break
                      LocalGet "entry_ptr",
                      I32Load (fromIntegral ABI.denvEntryKeyOffset),
                      LocalGet "key",
                      I32Eq,
                      IfVoid
                        [ LocalGet "entry_ptr",
                          I32Load (fromIntegral ABI.denvEntryValueOffset),
                          LocalSet "result",
                          Br "lookup_done"
                        ]
                        [ -- i++
                          LocalGet "i",
                          I32Const 1,
                          I32Add,
                          LocalSet "i",
                          Br "lookup_loop"
                        ]
                    ]
                ]
            ],
          -- Return result
          LocalGet "result"
        ]
    }

-- | DEnv insert: @__denv_insert(denv_ptr, key, value) -> i32@ (new denv_ptr)
-- If key exists, updates in place. If not, adds new entry.
-- For MVP, we copy and add (immutable semantics like the native runtime).
denvInsertFunction :: WatFunction
denvInsertFunction =
  WatFunction
    { funcName = "__denv_insert",
      funcParams = [("denv_ptr", I32), ("key", I32), ("value", I32)],
      funcLocals = [("new_ptr", I32), ("count", I32), ("i", I32), ("src_entry", I32), ("dst_entry", I32)],
      funcResults = [I32],
      funcBody =
        [ Comment "Insert handler into DEnv (creates new DEnv with entry added/updated)",
          -- If denv_ptr is 0 (null), create new DEnv with single entry
          LocalGet "denv_ptr",
          I32Eqz,
          If I32
            [ -- Create new DEnv with count=1
              I32Const (fromIntegral $ ABI.denvSize 1),
              Call "__alloc",
              LocalSet "new_ptr",
              -- Set count = 1
              LocalGet "new_ptr",
              I32Const 1,
              I32Store (fromIntegral ABI.denvCountOffset),
              -- Set entry[0].key = key
              LocalGet "new_ptr",
              I32Const (fromIntegral ABI.denvEntriesOffset),
              I32Add,
              LocalGet "key",
              I32Store (fromIntegral ABI.denvEntryKeyOffset),
              -- Set entry[0].value = value
              LocalGet "new_ptr",
              I32Const (fromIntegral ABI.denvEntriesOffset),
              I32Add,
              LocalGet "value",
              I32Store (fromIntegral ABI.denvEntryValueOffset),
              LocalGet "new_ptr"
            ]
            [ -- Load existing count
              LocalGet "denv_ptr",
              I32Load (fromIntegral ABI.denvCountOffset),
              LocalSet "count",
              -- Allocate new DEnv with count+1 entries
              I32Const (fromIntegral ABI.denvBaseSize),
              LocalGet "count",
              I32Const 1,
              I32Add,
              I32Const (fromIntegral ABI.denvEntrySize),
              I32Mul,
              I32Add,
              Call "__alloc",
              LocalSet "new_ptr",
              -- Set count = count + 1
              LocalGet "new_ptr",
              LocalGet "count",
              I32Const 1,
              I32Add,
              I32Store (fromIntegral ABI.denvCountOffset),
              -- Copy existing entries
              I32Const 0,
              LocalSet "i",
              Block "copy_done"
                [ Loop "copy_loop"
                    [ LocalGet "i",
                      LocalGet "count",
                      I32GeU,
                      BrIf "copy_done",
                      -- src_entry = denv_ptr + entriesOffset + i * entrySize
                      LocalGet "denv_ptr",
                      I32Const (fromIntegral ABI.denvEntriesOffset),
                      I32Add,
                      LocalGet "i",
                      I32Const (fromIntegral ABI.denvEntrySize),
                      I32Mul,
                      I32Add,
                      LocalSet "src_entry",
                      -- dst_entry = new_ptr + entriesOffset + i * entrySize
                      LocalGet "new_ptr",
                      I32Const (fromIntegral ABI.denvEntriesOffset),
                      I32Add,
                      LocalGet "i",
                      I32Const (fromIntegral ABI.denvEntrySize),
                      I32Mul,
                      I32Add,
                      LocalSet "dst_entry",
                      -- Copy key
                      LocalGet "dst_entry",
                      LocalGet "src_entry",
                      I32Load (fromIntegral ABI.denvEntryKeyOffset),
                      I32Store (fromIntegral ABI.denvEntryKeyOffset),
                      -- Copy value
                      LocalGet "dst_entry",
                      LocalGet "src_entry",
                      I32Load (fromIntegral ABI.denvEntryValueOffset),
                      I32Store (fromIntegral ABI.denvEntryValueOffset),
                      -- i++
                      LocalGet "i",
                      I32Const 1,
                      I32Add,
                      LocalSet "i",
                      Br "copy_loop"
                    ]
                ],
              -- Add new entry at index 'count'
              -- dst_entry = new_ptr + entriesOffset + count * entrySize
              LocalGet "new_ptr",
              I32Const (fromIntegral ABI.denvEntriesOffset),
              I32Add,
              LocalGet "count",
              I32Const (fromIntegral ABI.denvEntrySize),
              I32Mul,
              I32Add,
              LocalSet "dst_entry",
              -- Set key
              LocalGet "dst_entry",
              LocalGet "key",
              I32Store (fromIntegral ABI.denvEntryKeyOffset),
              -- Set value
              LocalGet "dst_entry",
              LocalGet "value",
              I32Store (fromIntegral ABI.denvEntryValueOffset),
              LocalGet "new_ptr"
            ]
        ]
    }

--------------------------------------------------------------------------------
-- K Frame Allocation Functions
--------------------------------------------------------------------------------

-- | Push frame allocation: @__alloc_push(saved_count, pending_args, comb_ref, comb_idx) -> i32@
--
-- Allocates a Push frame for function returns. Caller fills in saved locals.
allocPushFrameFunction :: WatFunction
allocPushFrameFunction =
  WatFunction
    { funcName = "__alloc_push",
      funcParams =
        [ ("saved_count", I32),
          ("pending_args", I32),
          ("comb_ref", I32),
          ("comb_idx", I32)
        ],
      funcLocals = [("ptr", I32), ("size", I32)],
      funcResults = [I32],
      funcBody =
        [ Comment "Allocate Push frame: header + comb_ix + saved locals",
          -- size = kPushBaseSize + saved_count * typedSlotSize
          I32Const (fromIntegral ABI.kPushBaseSize),
          LocalGet "saved_count",
          I32Const (fromIntegral ABI.typedSlotSize),
          I32Mul,
          I32Add,
          LocalSet "size",
          -- Allocate
          LocalGet "size",
          Call "__alloc",
          LocalSet "ptr",
          -- Write FrameTag (0x01) at byte 0
          LocalGet "ptr",
          I32Const (fromIntegral (ABI.frameTagToWord8 ABI.framePush)),
          I32Store8 0,
          -- Write Next K ptr at offset 4 (current k_ptr)
          LocalGet "ptr",
          GlobalGet "k_ptr",
          I32Store (fromIntegral ABI.kPushNextKOffset),
          -- Write SavedCount at offset 8
          LocalGet "ptr",
          LocalGet "saved_count",
          I32Store (fromIntegral ABI.kPushSavedCountOffset),
          -- Write PendingArgs at offset 12
          LocalGet "ptr",
          LocalGet "pending_args",
          I32Store (fromIntegral ABI.kPushPendingArgsOffset),
          -- Write CombIx: Reference at offset 16
          LocalGet "ptr",
          LocalGet "comb_ref",
          I32Store (fromIntegral ABI.kPushCombIxOffset),
          -- Write CombIx: Comb# at offset 20
          LocalGet "ptr",
          LocalGet "comb_idx",
          I32Store (fromIntegral ABI.kPushCombIxOffset + 4),
          -- Return pointer (caller fills saved locals at offset 24+)
          LocalGet "ptr"
        ]
    }

-- | Mark frame allocation: @__alloc_mark(pending_args, ability_ref, handler_ptr) -> i32@
--
-- Allocates a Mark frame for ability handlers.
allocMarkFrameFunction :: WatFunction
allocMarkFrameFunction =
  WatFunction
    { funcName = "__alloc_mark",
      funcParams =
        [ ("pending_args", I32),
          ("ability_ref", I32),
          ("handler_ptr", I32)
        ],
      funcLocals = [("ptr", I32)],
      funcResults = [I32],
      funcBody =
        [ Comment "Allocate Mark frame: fixed size for ability handler",
          -- Allocate kMarkBaseSize bytes
          I32Const (fromIntegral ABI.kMarkBaseSize),
          Call "__alloc",
          LocalSet "ptr",
          -- Write FrameTag (0x02) at byte 0
          LocalGet "ptr",
          I32Const (fromIntegral (ABI.frameTagToWord8 ABI.frameMark)),
          I32Store8 0,
          -- Write Next K ptr at offset 4 (current k_ptr)
          LocalGet "ptr",
          GlobalGet "k_ptr",
          I32Store (fromIntegral ABI.kMarkNextKOffset),
          -- Write PendingArgs at offset 8
          LocalGet "ptr",
          LocalGet "pending_args",
          I32Store (fromIntegral ABI.kMarkPendingArgsOffset),
          -- Write AbilityRef at offset 12
          LocalGet "ptr",
          LocalGet "ability_ref",
          I32Store (fromIntegral ABI.kMarkAbilityRefOffset),
          -- Write Handler ptr at offset 16
          LocalGet "ptr",
          LocalGet "handler_ptr",
          I32Store (fromIntegral ABI.kMarkHandlerPtrOffset),
          -- Write saved DEnv at offset 20 (current denv_ptr)
          LocalGet "ptr",
          GlobalGet "denv_ptr",
          I32Store (fromIntegral ABI.kMarkLocalCountOffset),
          -- Return pointer
          LocalGet "ptr"
        ]
    }

--------------------------------------------------------------------------------
-- Aggregated Runtime
--------------------------------------------------------------------------------

-- | All runtime helper functions
runtimeFunctions :: [WatFunction]
runtimeFunctions =
  [ allocFunction,
    allocPApFunction,
    allocData1Function,
    allocData2Function,
    allocDataGFunction,
    allocCapturedFunction,
    allocTextFunction,
    allocPushFrameFunction,
    allocMarkFrameFunction,
    -- DEnv functions
    allocDenvFunction,
    denvLookupFunction,
    denvInsertFunction,
    -- Async continuation functions
    allocAsyncContFunction,
    allocLocalsArrayFunction,
    resumeFunction,
    resumeWithErrorFunction,
    allocData1RawFunction
  ]
    ++ map mkApplyFunction [1 .. 3] -- Generate __apply1, __apply2, __apply3

--------------------------------------------------------------------------------
-- Async Continuation Support
--------------------------------------------------------------------------------

-- | Allocate an async continuation object:
-- @__alloc_async_cont(cont_id, k_ptr, denv_ptr, locals_ptr, locals_count, func_idx, resume_label, arity) -> i32@
--
-- Creates an OBJ_ASYNC_CONT object to store the suspended computation state.
-- Includes the dynamic environment pointer for handler preservation across async.
-- Includes function arity for call_indirect type dispatch when resuming.
allocAsyncContFunction :: WatFunction
allocAsyncContFunction =
  WatFunction
    { funcName = "__alloc_async_cont",
      funcParams =
        [ ("cont_id", I64),
          ("k_ptr", I32),
          ("denv_ptr", I32),
          ("locals_ptr", I32),
          ("locals_count", I32),
          ("func_idx", I32),
          ("resume_label", I32),
          ("arity", I32)
        ],
      funcLocals = [("ptr", I32)],
      funcResults = [I32],
      funcBody =
        [ Comment "Allocate OBJ_ASYNC_CONT object",
          -- ptr = __alloc(asyncContSize)
          I32Const (fromIntegral ABI.asyncContSize),
          Call "__alloc",
          LocalSet "ptr",
          -- Write header: OBJ_ASYNC_CONT
          LocalGet "ptr",
          I64Const (fromIntegral (ABI.objTagToWord16 ABI.objAsyncCont)),
          I64Const 48,
          I64Shl,
          I64Const (fromIntegral ABI.asyncContSize),
          I64Or,
          I64Store 0,
          -- Write cont_id at offset 8
          LocalGet "ptr",
          LocalGet "cont_id",
          I64Store (fromIntegral ABI.asyncContIdOffset),
          -- Write k_ptr at offset 16
          LocalGet "ptr",
          LocalGet "k_ptr",
          I32Store (fromIntegral ABI.asyncContKPtrOffset),
          -- Write denv_ptr at offset 20
          LocalGet "ptr",
          LocalGet "denv_ptr",
          I32Store (fromIntegral ABI.asyncContDEnvPtrOffset),
          -- Write locals_ptr at offset 24
          LocalGet "ptr",
          LocalGet "locals_ptr",
          I32Store (fromIntegral ABI.asyncContLocalsPtrOffset),
          -- Write locals_count at offset 28
          LocalGet "ptr",
          LocalGet "locals_count",
          I32Store (fromIntegral ABI.asyncContLocalsCountOffset),
          -- Write func_idx at offset 32
          LocalGet "ptr",
          LocalGet "func_idx",
          I32Store (fromIntegral ABI.asyncContFuncIdxOffset),
          -- Write resume_label at offset 36
          LocalGet "ptr",
          LocalGet "resume_label",
          I32Store (fromIntegral ABI.asyncContResumeLabelOffset),
          -- Write status = PENDING at offset 40
          LocalGet "ptr",
          I32Const (fromIntegral ABI.asyncStatusPending),
          I32Store (fromIntegral ABI.asyncContStatusOffset),
          -- Write arity at offset 44
          LocalGet "ptr",
          LocalGet "arity",
          I32Store (fromIntegral ABI.asyncContArityOffset),
          -- Return ptr
          LocalGet "ptr"
        ]
    }

-- | Allocate a locals array: @__alloc_locals_array(count) -> i32@
--
-- Creates a heap block to store N i64 local values.
-- Each local is stored as 8 bytes (i64).
allocLocalsArrayFunction :: WatFunction
allocLocalsArrayFunction =
  WatFunction
    { funcName = "__alloc_locals_array",
      funcParams = [("count", I32)],
      funcLocals = [("ptr", I32)],
      funcResults = [I32],
      funcBody =
        [ Comment "Allocate locals array (count * 8 bytes)",
          LocalGet "count",
          I32Const 8,
          I32Mul,
          Call "__alloc",
          LocalSet "ptr",
          LocalGet "ptr"
        ]
    }

-- | Resume function: @__resume(cont_id, value) -> i64@
--
-- Called by JS to resume a yielded computation.
-- This function:
-- 1. Validates the continuation ID matches
-- 2. Loads the saved state from the async cont object into globals
-- 3. Sets the __async_resuming flag
-- 4. Stores the resume value in __async_resume_value
-- 5. Dispatches to call_indirect with correct arity based on saved arity
resumeFunction :: WatFunction
resumeFunction =
  WatFunction
    { funcName = "__resume",
      funcParams = [("cont_id", I64), ("value", I64)],
      funcLocals = [("cont_ptr", I32), ("func_idx", I32), ("arity", I32)],
      funcResults = [I64],
      funcBody =
        [ Comment "Resume a suspended async computation",
          -- Get the async cont pointer from global
          GlobalGet "async_cont_ptr",
          LocalSet "cont_ptr",

          -- Validate cont_id matches
          LocalGet "cont_ptr",
          I64Load (fromIntegral ABI.asyncContIdOffset),
          LocalGet "cont_id",
          I64Eq,
          I32Eqz,
          -- If mismatch, trap (invalid continuation)
          IfVoid [Unreachable] [],

          -- Check status is Pending (0)
          LocalGet "cont_ptr",
          I32Load (fromIntegral ABI.asyncContStatusOffset),
          -- If not 0, trap (already resumed or freed)
          IfVoid [Unreachable] [],

          -- Mark as Resumed (1)
          LocalGet "cont_ptr",
          I32Const (fromIntegral ABI.asyncStatusResumed),
          I32Store (fromIntegral ABI.asyncContStatusOffset),

          -- Store the resume value in global (to be picked up by state machine)
          LocalGet "value",
          GlobalSet "__async_resume_value",

          -- Set the resuming flag
          I32Const 1,
          GlobalSet "__async_resuming",

          -- Load function index and arity from AsyncCont
          LocalGet "cont_ptr",
          I32Load (fromIntegral ABI.asyncContFuncIdxOffset),
          LocalSet "func_idx",

          LocalGet "cont_ptr",
          I32Load (fromIntegral ABI.asyncContArityOffset),
          LocalSet "arity",

          -- Dispatch call_indirect based on arity
          -- All params are dummy values (0); the function will restore from saved locals
          Comment "Dispatch call_indirect based on arity",
          LocalGet "arity",
          I32Const 1,
          I32Eq,
          If I64
            -- Arity 1: pass one dummy param
            [ I64Const 0,
              LocalGet "func_idx",
              CallIndirect "arity_1"
            ]
            -- Check for arity 2
            [ LocalGet "arity",
              I32Const 2,
              I32Eq,
              If I64
                -- Arity 2: pass two dummy params
                [ I64Const 0,
                  I64Const 0,
                  LocalGet "func_idx",
                  CallIndirect "arity_2"
                ]
                -- Check for arity 3
                [ LocalGet "arity",
                  I32Const 3,
                  I32Eq,
                  If I64
                    -- Arity 3
                    [ I64Const 0,
                      I64Const 0,
                      I64Const 0,
                      LocalGet "func_idx",
                      CallIndirect "arity_3"
                    ]
                    -- Check for arity 4
                    [ LocalGet "arity",
                      I32Const 4,
                      I32Eq,
                      If I64
                        -- Arity 4
                        [ I64Const 0,
                          I64Const 0,
                          I64Const 0,
                          I64Const 0,
                          LocalGet "func_idx",
                          CallIndirect "arity_4"
                        ]
                        -- Check for arity 5
                        [ LocalGet "arity",
                          I32Const 5,
                          I32Eq,
                          If I64
                            -- Arity 5
                            [ I64Const 0,
                              I64Const 0,
                              I64Const 0,
                              I64Const 0,
                              I64Const 0,
                              LocalGet "func_idx",
                              CallIndirect "arity_5"
                            ]
                            -- Default: arity 6
                            [ I64Const 0,
                              I64Const 0,
                              I64Const 0,
                              I64Const 0,
                              I64Const 0,
                              I64Const 0,
                              LocalGet "func_idx",
                              CallIndirect "arity_6"
                            ]
                        ]
                    ]
                ]
            ]
        ]
    }

-- | Resume with error function: @__resume_with_error(cont_id, failure_ptr) -> i64@
--
-- Called by JS to resume a yielded computation with a Failure value.
-- This wraps the failure in Left and resumes.
-- The failure_ptr should point to a DataG with Failure type reference.
resumeWithErrorFunction :: WatFunction
resumeWithErrorFunction =
  WatFunction
    { funcName = "__resume_with_error",
      funcParams = [("cont_id", I64), ("failure_ptr", I64)],
      funcLocals = [("cont_ptr", I32), ("func_idx", I32), ("arity", I32), ("left_ptr", I32)],
      funcResults = [I64],
      funcBody =
        [ Comment "Resume a suspended async computation with an error",
          -- Get the async cont pointer from global
          GlobalGet "async_cont_ptr",
          LocalSet "cont_ptr",

          -- Validate cont_id matches
          LocalGet "cont_ptr",
          I64Load (fromIntegral ABI.asyncContIdOffset),
          LocalGet "cont_id",
          I64Eq,
          I32Eqz,
          -- If mismatch, trap (invalid continuation)
          IfVoid [Unreachable] [],

          -- Check status is Pending (0)
          LocalGet "cont_ptr",
          I32Load (fromIntegral ABI.asyncContStatusOffset),
          -- If not 0, trap (already resumed or freed)
          IfVoid [Unreachable] [],

          -- Mark as Error (3)
          LocalGet "cont_ptr",
          I32Const (fromIntegral ABI.asyncStatusError),
          I32Store (fromIntegral ABI.asyncContStatusOffset),

          -- Allocate Left wrapper: Data1 with typeRef=0, ctorTag=0 (Left), field0=failure_ptr
          -- TypeRef 0 is placeholder for Either
          I32Const 0,        -- typeRef (Either placeholder)
          I32Const 0,        -- ctorTag (Left = 0)
          I32Const (fromIntegral (ABI.typeTagToWord8 ABI.typeBoxed)), -- TypeTag for boxed
          LocalGet "failure_ptr",
          I32WrapI64,        -- Convert i64 ptr to i32
          Call "__alloc_data1_raw",
          LocalSet "left_ptr",

          -- Store the Left pointer as resume value (as i64)
          LocalGet "left_ptr",
          I64ExtendI32U,
          GlobalSet "__async_resume_value",

          -- Set the resuming flag
          I32Const 1,
          GlobalSet "__async_resuming",

          -- Load function index and arity from AsyncCont
          LocalGet "cont_ptr",
          I32Load (fromIntegral ABI.asyncContFuncIdxOffset),
          LocalSet "func_idx",

          LocalGet "cont_ptr",
          I32Load (fromIntegral ABI.asyncContArityOffset),
          LocalSet "arity",

          -- Dispatch call_indirect based on arity
          Comment "Dispatch call_indirect based on arity",
          LocalGet "arity",
          I32Const 1,
          I32Eq,
          If I64
            [ I64Const 0,
              LocalGet "func_idx",
              CallIndirect "arity_1"
            ]
            [ LocalGet "arity",
              I32Const 2,
              I32Eq,
              If I64
                [ I64Const 0,
                  I64Const 0,
                  LocalGet "func_idx",
                  CallIndirect "arity_2"
                ]
                [ LocalGet "arity",
                  I32Const 3,
                  I32Eq,
                  If I64
                    [ I64Const 0,
                      I64Const 0,
                      I64Const 0,
                      LocalGet "func_idx",
                      CallIndirect "arity_3"
                    ]
                    [ LocalGet "arity",
                      I32Const 4,
                      I32Eq,
                      If I64
                        [ I64Const 0,
                          I64Const 0,
                          I64Const 0,
                          I64Const 0,
                          LocalGet "func_idx",
                          CallIndirect "arity_4"
                        ]
                        [ LocalGet "arity",
                          I32Const 5,
                          I32Eq,
                          If I64
                            [ I64Const 0,
                              I64Const 0,
                              I64Const 0,
                              I64Const 0,
                              I64Const 0,
                              LocalGet "func_idx",
                              CallIndirect "arity_5"
                            ]
                            [ I64Const 0,
                              I64Const 0,
                              I64Const 0,
                              I64Const 0,
                              I64Const 0,
                              I64Const 0,
                              LocalGet "func_idx",
                              CallIndirect "arity_6"
                            ]
                        ]
                    ]
                ]
            ]
        ]
    }

-- | Allocate a Data1 object (raw version for runtime use):
-- @__alloc_data1_raw(typeRef, ctorTag, field_tag, field_payload_low) -> i32@
--
-- This is a simplified version for runtime use that takes the payload directly.
allocData1RawFunction :: WatFunction
allocData1RawFunction =
  WatFunction
    { funcName = "__alloc_data1_raw",
      funcParams = [("type_ref", I32), ("ctor_tag", I32), ("field_tag", I32), ("field_payload", I32)],
      funcLocals = [("ptr", I32)],
      funcResults = [I32],
      funcBody =
        [ Comment "Allocate OBJ_DATA1 object",
          -- Allocate 32 bytes for Data1
          I32Const (fromIntegral ABI.data1Size),
          Call "__alloc",
          LocalSet "ptr",

          -- Write header: OBJ_DATA1 with arity=1
          LocalGet "ptr",
          I64Const (fromIntegral (ABI.objTagToWord16 ABI.objData1)),
          I64Const 48,
          I64Shl,
          I64Const 1, -- Arity = 1
          I64Or,
          I64Store 0,

          -- Write typeRef at offset 8
          LocalGet "ptr",
          LocalGet "type_ref",
          I32Store (fromIntegral ABI.data1TypeRefOffset),

          -- Write ctorTag at offset 12
          LocalGet "ptr",
          LocalGet "ctor_tag",
          I32Store (fromIntegral ABI.data1CtorIdOffset),

          -- Write field TypeTag at offset 16 (TypedSlot tag)
          LocalGet "ptr",
          LocalGet "field_tag",
          I64ExtendI32U,
          I64Store (fromIntegral ABI.data1Field0Offset),

          -- Write field payload at offset 24 (TypedSlot payload)
          LocalGet "ptr",
          LocalGet "field_payload",
          I64ExtendI32U,
          I64Store (fromIntegral (ABI.data1Field0Offset + 8)),

          -- Return pointer
          LocalGet "ptr"
        ]
    }
