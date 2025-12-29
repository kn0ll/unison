{-# LANGUAGE NumericUnderscores #-}

-- | ABI constants for WASM compilation target.
--
-- This module provides the canonical Haskell definitions for the WASM ABI
-- specified in unison-wasm/docs/ABI.md. These constants MUST match the JavaScript
-- runtime's abi-constants.ts exactly.
--
-- == ABI Version
-- Version: 0.1.0-draft
--
-- == Important Invariants
-- * All heap allocations are 8-byte aligned
-- * TypedSlot is 16 bytes (8-byte TypeTag region + 8-byte Payload64)
-- * Pointers are 32-bit offsets stored zero-extended in low bits of Payload64
module Unison.Wasm.ABI
  ( -- * ABI Version
    abiVersion,
    abiVersionMajor,
    abiVersionMinor,
    abiVersionPatch,

    -- * TypeTag Constants (8-bit discriminators)
    TypeTag (..),
    typeTagToWord8,
    typeTagFromWord8,
    typeNat,
    typeInt,
    typeFloat,
    typeChar,
    typeBoxed,

    -- * ObjTag Constants (12-bit discriminators)
    ObjTag (..),
    objTagToWord16,
    objTagFromWord16,
    objEnum,
    objData1,
    objData2,
    objDataG,
    objPAp,
    objCaptured,
    objForeign,
    objText,
    objBytes,
    objSequence,
    objAsyncCont,

    -- * Frame Tag Constants (8-bit)
    FrameTag (..),
    frameTagToWord8,
    frameTagFromWord8,
    frameKE,
    framePush,
    frameMark,

    -- * Size Constants (bytes)
    typedSlotSize,
    headerSize,
    enumSize,
    data1Size,
    data2Size,
    pApBaseSize,
    capturedBaseSize,
    foreignSize,
    textBaseSize,
    bytesBaseSize,
    sequenceBaseSize,
    kPushBaseSize,
    kMarkBaseSize,

    -- * Offset Constants (bytes from object start)
    -- ** Header offsets
    headerOffset,

    -- ** Enum offsets
    enumTypeRefOffset,
    enumCtorIdOffset,

    -- ** Data1 offsets
    data1TypeRefOffset,
    data1CtorIdOffset,
    data1Field0Offset,

    -- ** Data2 offsets
    data2TypeRefOffset,
    data2CtorIdOffset,
    data2Field0Offset,
    data2Field1Offset,

    -- ** DataG offsets
    dataGTypeRefOffset,
    dataGCtorIdOffset,
    dataGArityOffset,
    dataGFieldsOffset,

    -- ** PAp offsets
    pApFuncRefOffset,
    pApExpectedArityOffset,
    pApCapturedCountOffset,
    pApArgsOffset,

    -- ** Captured offsets
    capturedKPtrOffset,
    capturedCountOffset,
    capturedSlotsOffset,

    -- ** Foreign offsets
    foreignHandleIdOffset,

    -- ** Text offsets
    textLengthOffset,
    textDataOffset,

    -- ** Bytes offsets
    bytesLengthOffset,
    bytesDataOffset,

    -- ** Sequence offsets
    sequenceLengthOffset,
    sequenceElementsOffset,

    -- ** K Frame offsets (Push)
    kPushFrameTagOffset,
    kPushNextKOffset,
    kPushSavedCountOffset,
    kPushPendingArgsOffset,
    kPushCombIxOffset,
    kPushSavedLocalsOffset,
    -- Legacy aliases
    kPushReturnPCOffset,
    kPushLocalCountOffset,

    -- ** K Frame offsets (Mark)
    kMarkFrameTagOffset,
    kMarkNextKOffset,
    kMarkPendingArgsOffset,
    kMarkAbilityRefOffset,
    kMarkHandlerPtrOffset,
    kMarkLocalCountOffset,
    kMarkSavedLocalsOffset,

    -- * Header Encoding/Decoding
    encodeHeader,
    decodeHeader,
    HeaderFields (..),

    -- * Packed Tag Encoding/Decoding
    encodePackedTag,
    decodePackedTag,
    PackedTagFields (..),

    -- * Size Calculation Helpers
    dataGSize,
    pApSize,
    capturedSize,
    textSize,
    bytesSize,
    sequenceSize,
    kPushSize,
    kMarkSize,

    -- * DEnv (Dynamic Handler Environment) Constants
    denvEntrySize,
    denvMaxEntries,
    denvCountOffset,
    denvEntriesOffset,
    denvEntryKeyOffset,
    denvEntryValueOffset,
    denvBaseSize,
    denvSize,

    -- * TypedSlot Offset Helper
    slotPayloadOffset,

    -- * Async Continuation Constants
    asyncContSize,
    asyncContIdOffset,
    asyncContKPtrOffset,
    asyncContLocalsPtrOffset,
    asyncContLocalsCountOffset,
    asyncContStatusOffset,
    asyncStatusPending,
    asyncStatusResumed,
    asyncStatusFreed,
    yieldSentinel,

    -- * Alignment
    align8,

    -- * Memory Layout Constants
    memoryNullZoneStart,
    memoryNullZoneEnd,
    memoryGlobalsStart,
    memoryGlobalsEnd,
    memoryRefTablesStart,
    memoryRefTablesEnd,
    memoryHeapStart,
  )
where

import Data.Bits (Bits (shiftL, shiftR, (.&.), (.|.), xor))
import Data.Word (Word16, Word32, Word64, Word8)

-- -----------------------------------------------------------------------------
-- ABI Version
-- -----------------------------------------------------------------------------

-- | Full ABI version string
abiVersion :: String
abiVersion = "0.1.0-draft"

-- | Major version (breaking changes)
abiVersionMajor :: Word32
abiVersionMajor = 0

-- | Minor version (backward-compatible additions)
abiVersionMinor :: Word32
abiVersionMinor = 1

-- | Patch version (bug fixes)
abiVersionPatch :: Word32
abiVersionPatch = 0

-- -----------------------------------------------------------------------------
-- TypeTag Constants
-- -----------------------------------------------------------------------------

-- | TypeTag discriminates the payload interpretation of a TypedSlot.
-- These are 8-bit values.
newtype TypeTag = TypeTag {unTypeTag :: Word8}
  deriving (Eq, Ord, Show)

typeTagToWord8 :: TypeTag -> Word8
typeTagToWord8 = unTypeTag

typeTagFromWord8 :: Word8 -> Maybe TypeTag
typeTagFromWord8 w
  | w <= 0x04 = Just (TypeTag w)
  | otherwise = Nothing

-- | Natural number (unsigned 64-bit)
typeNat :: TypeTag
typeNat = TypeTag 0x00

-- | Integer (signed 64-bit)
typeInt :: TypeTag
typeInt = TypeTag 0x01

-- | Float (IEEE 754 double)
typeFloat :: TypeTag
typeFloat = TypeTag 0x02

-- | Char (Unicode codepoint)
typeChar :: TypeTag
typeChar = TypeTag 0x03

-- | Boxed value (pointer to heap object)
typeBoxed :: TypeTag
typeBoxed = TypeTag 0x04

-- -----------------------------------------------------------------------------
-- ObjTag Constants
-- -----------------------------------------------------------------------------

-- | ObjTag discriminates heap object kinds.
-- These are 12-bit values stored in the header.
newtype ObjTag = ObjTag {unObjTag :: Word16}
  deriving (Eq, Ord, Show)

objTagToWord16 :: ObjTag -> Word16
objTagToWord16 = unObjTag

objTagFromWord16 :: Word16 -> Maybe ObjTag
objTagFromWord16 w
  | w >= 0x001 && w <= 0x00B = Just (ObjTag w)
  | otherwise = Nothing

-- | Enum (nullary constructor)
objEnum :: ObjTag
objEnum = ObjTag 0x001

-- | Data with 1 field
objData1 :: ObjTag
objData1 = ObjTag 0x002

-- | Data with 2 fields
objData2 :: ObjTag
objData2 = ObjTag 0x003

-- | Data with N fields (general)
objDataG :: ObjTag
objDataG = ObjTag 0x004

-- | Partial application
objPAp :: ObjTag
objPAp = ObjTag 0x005

-- | Captured continuation
objCaptured :: ObjTag
objCaptured = ObjTag 0x006

-- | Foreign (opaque JS handle)
objForeign :: ObjTag
objForeign = ObjTag 0x007

-- | UTF-8 text
objText :: ObjTag
objText = ObjTag 0x008

-- | Byte array
objBytes :: ObjTag
objBytes = ObjTag 0x009

-- | Immutable sequence
objSequence :: ObjTag
objSequence = ObjTag 0x00A

-- | Async continuation (for yield/resume)
objAsyncCont :: ObjTag
objAsyncCont = ObjTag 0x00B

-- -----------------------------------------------------------------------------
-- Frame Tag Constants
-- -----------------------------------------------------------------------------

-- | FrameTag discriminates K frame types.
-- These are 8-bit values.
newtype FrameTag = FrameTag {unFrameTag :: Word8}
  deriving (Eq, Ord, Show)

frameTagToWord8 :: FrameTag -> Word8
frameTagToWord8 = unFrameTag

frameTagFromWord8 :: Word8 -> Maybe FrameTag
frameTagFromWord8 w
  | w <= 0x02 = Just (FrameTag w)
  | otherwise = Nothing

-- | Empty continuation (stack bottom)
frameKE :: FrameTag
frameKE = FrameTag 0x00

-- | Push frame (normal return)
framePush :: FrameTag
framePush = FrameTag 0x01

-- | Mark frame (ability handler)
frameMark :: FrameTag
frameMark = FrameTag 0x02

-- -----------------------------------------------------------------------------
-- Size Constants (bytes)
-- -----------------------------------------------------------------------------

-- | TypedSlot: TypeTag (8 bytes padded) + Payload64 (8 bytes)
typedSlotSize :: Word32
typedSlotSize = 16

-- | Heap object header size
headerSize :: Word32
headerSize = 8

-- | Enum: header + packed tag
enumSize :: Word32
enumSize = 16

-- | Data1: header + packed tag + 1 field
data1Size :: Word32
data1Size = 32

-- | Data2: header + packed tag + 2 fields
data2Size :: Word32
data2Size = 48

-- | PAp base: header + func ref + arity info (before args)
pApBaseSize :: Word32
pApBaseSize = 24

-- | Captured base: header + k ptr + count (before slots)
capturedBaseSize :: Word32
capturedBaseSize = 16

-- | Foreign: header + handle ID
foreignSize :: Word32
foreignSize = 16

-- | Text base: header + length (before data)
textBaseSize :: Word32
textBaseSize = 16

-- | Bytes base: header + length (before data)
bytesBaseSize :: Word32
bytesBaseSize = 16

-- | Sequence base: header + length (before elements)
sequenceBaseSize :: Word32
sequenceBaseSize = 16

-- | KPush base: FrameTag+Reserved+Next (8) + SavedCount+PendingArgs (8) + CombIx (8)
-- = 24 bytes before saved locals
kPushBaseSize :: Word32
kPushBaseSize = 24

-- | KMark base: FrameTag+Reserved+Next (8) + PendingArgs+AbilitySet (8) + SavedDEnv+Reserved (8)
-- = 24 bytes (fixed size, no saved locals in Mark frames)
kMarkBaseSize :: Word32
kMarkBaseSize = 24

-- -----------------------------------------------------------------------------
-- Offset Constants
-- -----------------------------------------------------------------------------

-- Header is always at offset 0
headerOffset :: Word32
headerOffset = 0

-- Enum offsets
enumTypeRefOffset :: Word32
enumTypeRefOffset = 8

enumCtorIdOffset :: Word32
enumCtorIdOffset = 12

-- Data1 offsets
data1TypeRefOffset :: Word32
data1TypeRefOffset = 8

data1CtorIdOffset :: Word32
data1CtorIdOffset = 12

data1Field0Offset :: Word32
data1Field0Offset = 16

-- Data2 offsets
data2TypeRefOffset :: Word32
data2TypeRefOffset = 8

data2CtorIdOffset :: Word32
data2CtorIdOffset = 12

data2Field0Offset :: Word32
data2Field0Offset = 16

data2Field1Offset :: Word32
data2Field1Offset = 32

-- DataG offsets
dataGTypeRefOffset :: Word32
dataGTypeRefOffset = 8

dataGCtorIdOffset :: Word32
dataGCtorIdOffset = 12

dataGArityOffset :: Word32
dataGArityOffset = 14

dataGFieldsOffset :: Word32
dataGFieldsOffset = 16

-- PAp offsets
pApFuncRefOffset :: Word32
pApFuncRefOffset = 8

pApExpectedArityOffset :: Word32
pApExpectedArityOffset = 16

pApCapturedCountOffset :: Word32
pApCapturedCountOffset = 18

pApArgsOffset :: Word32
pApArgsOffset = 24

-- Captured offsets
capturedKPtrOffset :: Word32
capturedKPtrOffset = 8

capturedCountOffset :: Word32
capturedCountOffset = 12

capturedSlotsOffset :: Word32
capturedSlotsOffset = 16

-- Foreign offsets
foreignHandleIdOffset :: Word32
foreignHandleIdOffset = 8

-- Text offsets
textLengthOffset :: Word32
textLengthOffset = 8

textDataOffset :: Word32
textDataOffset = 16

-- Bytes offsets
bytesLengthOffset :: Word32
bytesLengthOffset = 8

bytesDataOffset :: Word32
bytesDataOffset = 16

-- Sequence offsets
sequenceLengthOffset :: Word32
sequenceLengthOffset = 8

sequenceElementsOffset :: Word32
sequenceElementsOffset = 16

-- K Frame offsets
-- Layout matches WASM_ABI.md Push Frame specification:
--   bytes 0-7:   FrameTag (8) + Reserved (24) + Next (32)
--   bytes 8-15:  SavedCount (32) + PendingArgs (32)
--   bytes 16-23: CombIx: Reference (32) + Comb# (32)
--   bytes 24+:   Saved[0..SavedCount-1]: TypedSlot (128 bits each)

-- KPush frame offsets
kPushFrameTagOffset :: Word32
kPushFrameTagOffset = 0

kPushNextKOffset :: Word32
kPushNextKOffset = 4

kPushSavedCountOffset :: Word32
kPushSavedCountOffset = 8

kPushPendingArgsOffset :: Word32
kPushPendingArgsOffset = 12

kPushCombIxOffset :: Word32
kPushCombIxOffset = 16

kPushSavedLocalsOffset :: Word32
kPushSavedLocalsOffset = 24

-- Legacy aliases for compatibility
kPushReturnPCOffset :: Word32
kPushReturnPCOffset = kPushCombIxOffset

kPushLocalCountOffset :: Word32
kPushLocalCountOffset = kPushSavedCountOffset

-- KMark frame offsets
-- Layout:
--   bytes 0-7:   FrameTag (8) + Reserved (24) + Next (32)
--   bytes 8-15:  PendingArgs (32) + AbilitySet ptr (32)
--   bytes 16-23: SavedDEnv pointer (32) + Reserved (32)
kMarkFrameTagOffset :: Word32
kMarkFrameTagOffset = 0

kMarkNextKOffset :: Word32
kMarkNextKOffset = 4

kMarkPendingArgsOffset :: Word32
kMarkPendingArgsOffset = 8

kMarkAbilityRefOffset :: Word32
kMarkAbilityRefOffset = 12

kMarkHandlerPtrOffset :: Word32
kMarkHandlerPtrOffset = 16

-- Mark frames don't have saved locals in the same way Push frames do
kMarkLocalCountOffset :: Word32
kMarkLocalCountOffset = 20

kMarkSavedLocalsOffset :: Word32
kMarkSavedLocalsOffset = 24

-- -----------------------------------------------------------------------------
-- Header Encoding/Decoding
-- -----------------------------------------------------------------------------

-- | Decoded header fields
data HeaderFields = HeaderFields
  { hfVersion :: !Word8,
    -- ^ 4-bit ABI version
    hfObjTag :: !ObjTag,
    -- ^ 12-bit object tag
    hfReserved :: !Word16,
    -- ^ 16 reserved bits
    hfSize :: !Word32
    -- ^ 32-bit object size in bytes
  }
  deriving (Eq, Show)

-- | Encode header fields into a 64-bit value
--
-- Layout: [Version:4 | ObjTag:12 | Reserved:16 | Size:32]
encodeHeader :: HeaderFields -> Word64
encodeHeader HeaderFields {hfVersion, hfObjTag, hfReserved, hfSize} =
  let v = fromIntegral hfVersion .&. 0x0F
      t = fromIntegral (unObjTag hfObjTag) .&. 0x0FFF
      r = fromIntegral hfReserved
      s = fromIntegral hfSize
   in (v `shiftL` 60)
        .|. (t `shiftL` 48)
        .|. (r `shiftL` 32)
        .|. s

-- | Decode a 64-bit header into its fields
decodeHeader :: Word64 -> HeaderFields
decodeHeader w =
  HeaderFields
    { hfVersion = fromIntegral ((w `shiftR` 60) .&. 0x0F),
      hfObjTag = ObjTag (fromIntegral ((w `shiftR` 48) .&. 0x0FFF)),
      hfReserved = fromIntegral ((w `shiftR` 32) .&. 0xFFFF),
      hfSize = fromIntegral (w .&. 0xFFFF_FFFF)
    }

-- -----------------------------------------------------------------------------
-- Packed Tag Encoding/Decoding
-- -----------------------------------------------------------------------------

-- | Decoded packed tag fields (for Data constructors)
data PackedTagFields = PackedTagFields
  { ptTypeRef :: !Word32,
    -- ^ Type reference ID
    ptCtorId :: !Word16,
    -- ^ Constructor ID within type
    ptArity :: !Word16
    -- ^ Field count (only for DataG)
  }
  deriving (Eq, Show)

-- | Encode packed tag into a 64-bit value
--
-- Layout: [TypeRef:32 | CtorId:16 | Arity:16]
encodePackedTag :: PackedTagFields -> Word64
encodePackedTag PackedTagFields {ptTypeRef, ptCtorId, ptArity} =
  let t = fromIntegral ptTypeRef
      c = fromIntegral ptCtorId
      a = fromIntegral ptArity
   in (t `shiftL` 32) .|. (c `shiftL` 16) .|. a

-- | Decode a 64-bit packed tag into its fields
decodePackedTag :: Word64 -> PackedTagFields
decodePackedTag w =
  PackedTagFields
    { ptTypeRef = fromIntegral ((w `shiftR` 32) .&. 0xFFFF_FFFF),
      ptCtorId = fromIntegral ((w `shiftR` 16) .&. 0xFFFF),
      ptArity = fromIntegral (w .&. 0xFFFF)
    }

-- -----------------------------------------------------------------------------
-- Size Calculation Helpers
-- -----------------------------------------------------------------------------

-- | Calculate DataG size: base + N * TypedSlot
dataGSize :: Word32 -> Word32
dataGSize arity = 16 + arity * typedSlotSize

-- | Calculate PAp size: base + N * TypedSlot
pApSize :: Word32 -> Word32
pApSize capturedCount = pApBaseSize + capturedCount * typedSlotSize

-- | Calculate Captured size: base + N * TypedSlot
capturedSize :: Word32 -> Word32
capturedSize slotCount = capturedBaseSize + slotCount * typedSlotSize

-- | Calculate Text size: base + byte length, aligned to 8 bytes
textSize :: Word32 -> Word32
textSize byteLen = align8 (textBaseSize + byteLen)

-- | Calculate Bytes size: base + byte length, aligned to 8 bytes
bytesSize :: Word32 -> Word32
bytesSize byteLen = align8 (bytesBaseSize + byteLen)

-- | Calculate Sequence size: base + N * TypedSlot
sequenceSize :: Word32 -> Word32
sequenceSize elementCount = sequenceBaseSize + elementCount * typedSlotSize

-- | Calculate KPush size: base + N * TypedSlot
kPushSize :: Word32 -> Word32
kPushSize localCount = align8 (kPushBaseSize + localCount * typedSlotSize)

-- | Calculate KMark size: base + N * TypedSlot
kMarkSize :: Word32 -> Word32
kMarkSize localCount = align8 (kMarkBaseSize + localCount * typedSlotSize)

-- -----------------------------------------------------------------------------
-- Alignment
-- -----------------------------------------------------------------------------

-- | Round up to 8-byte alignment
align8 :: Word32 -> Word32
align8 n = (n + 7) .&. (0xFFFF_FFFF `xor` 7)

-- -----------------------------------------------------------------------------
-- Memory Layout Constants
-- -----------------------------------------------------------------------------
-- Canonical layout: heap grows UP, stack grows DOWN
--
-- 0x0000 - 0x0FFF: Null trap zone (4KB)
-- 0x1000 - 0x1FFF: Runtime globals
-- 0x2000 - 0x3FFF: Reference tables
-- 0x4000+:         Heap (grows UP)
-- (top of memory): Stack (grows DOWN)

-- | Start of null trap zone
memoryNullZoneStart :: Word32
memoryNullZoneStart = 0x0000

-- | End of null trap zone (4KB)
memoryNullZoneEnd :: Word32
memoryNullZoneEnd = 0x0FFF

-- | Start of runtime globals region
memoryGlobalsStart :: Word32
memoryGlobalsStart = 0x1000

-- | End of runtime globals region
memoryGlobalsEnd :: Word32
memoryGlobalsEnd = 0x1FFF

-- | Start of reference tables region
memoryRefTablesStart :: Word32
memoryRefTablesStart = 0x2000

-- | End of reference tables region
memoryRefTablesEnd :: Word32
memoryRefTablesEnd = 0x3FFF

-- | Heap start - grows UP from here
memoryHeapStart :: Word32
memoryHeapStart = 0x4000

-- -----------------------------------------------------------------------------
-- DEnv (Dynamic Handler Environment) Constants
-- -----------------------------------------------------------------------------
-- DEnv is a simple array-based map from ability reference (u32) to handler pointer (u32).
-- Layout:
--   bytes 0-3:  count (u32) - number of entries
--   bytes 4+:   entries array, each entry is 8 bytes (key: u32, value: u32)

-- | Size of each DEnv entry (key + value)
denvEntrySize :: Word32
denvEntrySize = 8

-- | Maximum number of entries in a DEnv (for MVP)
denvMaxEntries :: Word32
denvMaxEntries = 16

-- | Offset to entry count
denvCountOffset :: Word32
denvCountOffset = 0

-- | Offset to entries array
denvEntriesOffset :: Word32
denvEntriesOffset = 4

-- | Offset within entry to key
denvEntryKeyOffset :: Word32
denvEntryKeyOffset = 0

-- | Offset within entry to value (handler ptr)
denvEntryValueOffset :: Word32
denvEntryValueOffset = 4

-- | Base size of DEnv (just count field)
denvBaseSize :: Word32
denvBaseSize = 4

-- | Calculate DEnv size for N entries
denvSize :: Word32 -> Word32
denvSize entryCount = align8 (denvBaseSize + entryCount * denvEntrySize)

-- -----------------------------------------------------------------------------
-- Async Continuation Constants
-- -----------------------------------------------------------------------------
-- OBJ_ASYNC_CONT represents a suspended async computation.
-- Layout:
--   bytes 0-7:   Header (ObjTag=0x00B, size=32)
--   bytes 8-15:  cont_id (i64) - unique ID for JS reference
--   bytes 16-19: k_ptr (i32) - saved K stack pointer
--   bytes 20-23: locals_ptr (i32) - pointer to saved locals array
--   bytes 24-27: locals_count (i32) - number of saved locals
--   bytes 28-31: status (i32) - 0=pending, 1=resumed, 2=freed

-- | Size of an async continuation object
asyncContSize :: Word32
asyncContSize = 32

-- | Offset of continuation ID
asyncContIdOffset :: Word32
asyncContIdOffset = 8

-- | Offset of saved K stack pointer
asyncContKPtrOffset :: Word32
asyncContKPtrOffset = 16

-- | Offset of saved locals pointer
asyncContLocalsPtrOffset :: Word32
asyncContLocalsPtrOffset = 20

-- | Offset of saved locals count
asyncContLocalsCountOffset :: Word32
asyncContLocalsCountOffset = 24

-- | Offset of status field
asyncContStatusOffset :: Word32
asyncContStatusOffset = 28

-- | Status: pending (not yet resumed)
asyncStatusPending :: Word32
asyncStatusPending = 0

-- | Status: resumed (consumed)
asyncStatusResumed :: Word32
asyncStatusResumed = 1

-- | Status: freed (cleaned up)
asyncStatusFreed :: Word32
asyncStatusFreed = 2

-- | Magic sentinel value indicating async yield
-- When a function returns this value, it means it yielded to JS.
-- Uses a value that cannot be a valid Nat/Int/pointer.
yieldSentinel :: Word64
yieldSentinel = 0xFFFF_FFFF_FFFF_FFFE

-- -----------------------------------------------------------------------------
-- TypedSlot Helper
-- -----------------------------------------------------------------------------

-- | Calculate offset to payload within a TypedSlot at a given index
-- Usage: slotPayloadOffset baseOffset slotIndex
slotPayloadOffset :: Word32 -> Word32 -> Word32
slotPayloadOffset baseOffset slotIndex =
  baseOffset + slotIndex * typedSlotSize + 8 -- +8 to skip TypeTag
