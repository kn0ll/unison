/**
 * ABI Constants for Unison WASM Runtime
 *
 * These constants are derived from: unison-wasm/docs/ABI.md
 * Changes must be kept in sync with ABI.md and src/Unison/Wasm/ABI.hs.
 *
 * @module abi-constants
 */

// =============================================================================
// Type Definitions
// =============================================================================

/** Object type tag (12 bits) */
export type ObjTag = number;

/** Type tag for TypedSlot payload (8 bits) */
export type TypeTag = number;

/** Frame tag for continuation frames (8 bits) */
export type FrameTag = number;

/** 32-bit pointer into WASM linear memory */
export type Ptr32 = number;

/** Decoded header information */
export interface DecodedHeader {
  version: number;
  objTag: ObjTag;
  size: number;
}

/** Decoded packed tag */
export interface DecodedPackedTag {
  rTag: number;
  cTag: number;
}

// =============================================================================
// ABI Version
// =============================================================================

/** Current ABI version (4 bits in header) */
export const ABI_VERSION = 0x0;

// =============================================================================
// Object Tags (OBJ_* prefix) - 12-bit discriminators for heap object types
// =============================================================================

/** Nullary data constructor (e.g., True, False, None) */
export const OBJ_ENUM: ObjTag = 0x001;

/** Unary data constructor (e.g., Some x) */
export const OBJ_DATA1: ObjTag = 0x002;

/** Binary data constructor (e.g., Pair a b) */
export const OBJ_DATA2: ObjTag = 0x003;

/** General data constructor with N fields */
export const OBJ_DATAG: ObjTag = 0x004;

/** Partial application / closure */
export const OBJ_PAP: ObjTag = 0x005;

/** Captured continuation */
export const OBJ_CAPTURED: ObjTag = 0x006;

/** Opaque reference to a JS value */
export const OBJ_FOREIGN: ObjTag = 0x007;

/** UTF-8 encoded text */
export const OBJ_TEXT: ObjTag = 0x008;

/** Raw byte array */
export const OBJ_BYTES: ObjTag = 0x009;

/** Unison sequence (list/array) */
export const OBJ_SEQUENCE: ObjTag = 0x00a;

/** Async continuation (for yield/resume) */
export const OBJ_ASYNC_CONT: ObjTag = 0x00b;

/** Map ObjTag values to human-readable names */
export const OBJ_TAG_NAMES: Record<ObjTag, string> = {
  [OBJ_ENUM]: 'Enum',
  [OBJ_DATA1]: 'Data1',
  [OBJ_DATA2]: 'Data2',
  [OBJ_DATAG]: 'DataG',
  [OBJ_PAP]: 'PAp',
  [OBJ_CAPTURED]: 'Captured',
  [OBJ_FOREIGN]: 'Foreign',
  [OBJ_TEXT]: 'Text',
  [OBJ_BYTES]: 'Bytes',
  [OBJ_SEQUENCE]: 'Sequence',
  [OBJ_ASYNC_CONT]: 'AsyncCont',
};

// =============================================================================
// Type Tags (TYPE_* prefix) - 8-bit discriminators for TypedSlot payloads
// =============================================================================

/** Unsigned 64-bit integer (Nat) */
export const TYPE_NAT: TypeTag = 0x00;

/** Signed 64-bit integer (Int) */
export const TYPE_INT: TypeTag = 0x01;

/** IEEE 754 double (Float) */
export const TYPE_FLOAT: TypeTag = 0x02;

/** Unicode codepoint (Char) - u32 in low bits */
export const TYPE_CHAR: TypeTag = 0x03;

/** Heap pointer (boxed value) - u32 in low bits */
export const TYPE_BOXED: TypeTag = 0x04;

/** Map TypeTag values to human-readable names */
export const TYPE_TAG_NAMES: Record<TypeTag, string> = {
  [TYPE_NAT]: 'Nat',
  [TYPE_INT]: 'Int',
  [TYPE_FLOAT]: 'Float',
  [TYPE_CHAR]: 'Char',
  [TYPE_BOXED]: 'Boxed',
};

// =============================================================================
// K Frame Tags (FRAME_* prefix) - 8-bit discriminators for continuation frames
// =============================================================================

/** Empty continuation (end of chain) */
export const FRAME_KE: FrameTag = 0x00;

/** Return frame with saved locals */
export const FRAME_PUSH: FrameTag = 0x01;

/** Ability handler marker frame */
export const FRAME_MARK: FrameTag = 0x02;

/** Map FrameTag values to human-readable names */
export const FRAME_TAG_NAMES: Record<FrameTag, string> = {
  [FRAME_KE]: 'KE',
  [FRAME_PUSH]: 'Push',
  [FRAME_MARK]: 'Mark',
};

// =============================================================================
// Sizes (in bytes)
// =============================================================================

/** Size of a TypedSlot (TypeTag + padding + Payload64) */
export const TYPED_SLOT_SIZE = 16;

/** Size of the common heap object header */
export const HEADER_SIZE = 8;

/** Size of PAp header (header + CombIx + arity fields) before args */
export const PAP_HEADER_SIZE = 24;

/** Size of Push frame header before saved locals */
export const PUSH_FRAME_HEADER_SIZE = 24;

/** Size of Mark frame (fixed) */
export const MARK_FRAME_SIZE = 24;

/** Size of Enum object (header + TypeRef + PackedTag) */
export const ENUM_SIZE = 16;

/** Size of Data1 object (header + TypeRef + PackedTag + 1 field) */
export const DATA1_SIZE = 32;

/** Size of Data2 object (header + TypeRef + PackedTag + 2 fields) */
export const DATA2_SIZE = 48;

/** Size of Foreign object (header + handle + typeHint) */
export const FOREIGN_SIZE = 16;

// =============================================================================
// Offsets within structures
// =============================================================================

// Header field extraction (64-bit header word)
// Layout: [Version(4) | ObjTag(12) | Reserved(16) | Size/Arity(32)]

/** Bit shift for version field in header */
export const HEADER_VERSION_SHIFT = 60n;

/** Bit mask for version field (4 bits) */
export const HEADER_VERSION_MASK = 0xfn;

/** Bit shift for ObjTag field in header */
export const HEADER_OBJTAG_SHIFT = 48n;

/** Bit mask for ObjTag field (12 bits) */
export const HEADER_OBJTAG_MASK = 0xfffn;

/** Bit mask for Size/Arity field (low 32 bits) */
export const HEADER_SIZE_MASK = 0xffffffffn;

// TypedSlot offsets
/** Offset of TypeTag within a TypedSlot */
export const SLOT_TAG_OFFSET = 0;

/** Offset of Payload64 within a TypedSlot */
export const SLOT_PAYLOAD_OFFSET = 8;

// Enum/Data offsets (after header)
/** Offset of TypeRef in Enum/Data objects */
export const DATA_TYPEREF_OFFSET = 8;

/** Offset of PackedTag in Enum/Data objects */
export const DATA_PACKEDTAG_OFFSET = 12;

/** Offset of first field in Data1/Data2/DataG */
export const DATA_FIELDS_OFFSET = 16;

// PAp offsets (after header)
/** Offset of CombIx RefId in PAp */
export const PAP_COMBIX_REFID_OFFSET = 8;

/** Offset of CombIx CombNum in PAp */
export const PAP_COMBIX_COMBNUM_OFFSET = 12;

/** Offset of ExpectedArity in PAp (u16) */
export const PAP_EXPECTED_ARITY_OFFSET = 16;

/** Offset of CapturedCount in PAp (u16) */
export const PAP_CAPTURED_COUNT_OFFSET = 18;

/** Offset of first captured arg in PAp */
export const PAP_ARGS_OFFSET = 24;

// Captured offsets (after header)
/** Offset of kHeadPtr in Captured */
export const CAPTURED_KHEAD_OFFSET = 8;

/** Offset of pendingArgs in Captured */
export const CAPTURED_PENDING_OFFSET = 12;

/** Offset of first captured value in Captured */
export const CAPTURED_VALUES_OFFSET = 16;

// Text/Bytes offsets (after header)
/** Offset of ByteLen in Text/Bytes */
export const TEXT_BYTELEN_OFFSET = 8;

/** Offset of CharLen in Text (Text only) */
export const TEXT_CHARLEN_OFFSET = 12;

/** Offset of raw bytes in Text/Bytes */
export const TEXT_BYTES_OFFSET = 16;

// Sequence offsets (after header)
/** Offset of Length in Sequence */
export const SEQ_LENGTH_OFFSET = 8;

/** Offset of Capacity in Sequence */
export const SEQ_CAPACITY_OFFSET = 12;

/** Offset of first element in Sequence */
export const SEQ_ELEMENTS_OFFSET = 16;

// Foreign offsets (after header)
/** Offset of JS handle ID in Foreign */
export const FOREIGN_HANDLE_OFFSET = 8;

/** Offset of TypeHint in Foreign */
export const FOREIGN_TYPEHINT_OFFSET = 12;

// K Frame offsets
/** Offset of FrameTag in K frame */
export const KFRAME_TAG_OFFSET = 0;

/** Offset of Next pointer in K frame */
export const KFRAME_NEXT_OFFSET = 4;

// Push frame offsets (after common header)
/** Offset of SavedCount in Push frame */
export const PUSH_SAVEDCOUNT_OFFSET = 8;

/** Offset of PendingArgs in Push frame */
export const PUSH_PENDINGARGS_OFFSET = 12;

/** Offset of CombIx in Push frame */
export const PUSH_COMBIX_OFFSET = 16;

/** Offset of first saved local in Push frame */
export const PUSH_SAVED_OFFSET = 24;

// Mark frame offsets (after common header)
/** Offset of PendingArgs in Mark frame */
export const MARK_PENDINGARGS_OFFSET = 8;

/** Offset of AbilitySet pointer in Mark frame */
export const MARK_ABILITIES_OFFSET = 12;

/** Offset of SavedDEnv pointer in Mark frame */
export const MARK_DENV_OFFSET = 16;

// =============================================================================
// Memory regions (canonical layout: heap UP, stack DOWN)
// =============================================================================

/** Start of null trap zone (accesses here are bugs) */
export const MEMORY_NULL_ZONE_START = 0x0000;

/** End of null trap zone (4KB) */
export const MEMORY_NULL_ZONE_END = 0x0fff;

/** Start of runtime globals region */
export const MEMORY_GLOBALS_START = 0x1000;

/** End of runtime globals region */
export const MEMORY_GLOBALS_END = 0x1fff;

/** Start of reference tables region */
export const MEMORY_REFTABLES_START = 0x2000;

/** End of reference tables region */
export const MEMORY_REFTABLES_END = 0x3fff;

/** Heap start - grows UP from here */
export const MEMORY_HEAP_START = 0x4000;

/**
 * Memory layout:
 * - Heap grows UP from MEMORY_HEAP_START (0x4000)
 * - Stack grows DOWN from top of memory
 * - They share the space between them and grow toward each other
 * - Collision triggers memory growth or OutOfMemoryError
 */

// =============================================================================
// Alignment
// =============================================================================

/** Required alignment for all heap objects */
export const HEAP_ALIGNMENT = 8;

// =============================================================================
// Helper functions for header encoding/decoding
// =============================================================================

/**
 * Encode a heap object header.
 */
export function encodeHeader(version: number, objTag: ObjTag, size: number): bigint {
  return (
    (BigInt(version & 0xf) << 60n) |
    (BigInt(objTag & 0xfff) << 48n) |
    BigInt(size >>> 0)
  );
}

/**
 * Decode a heap object header.
 */
export function decodeHeader(header: bigint): DecodedHeader {
  return {
    version: Number((header >> HEADER_VERSION_SHIFT) & HEADER_VERSION_MASK),
    objTag: Number((header >> HEADER_OBJTAG_SHIFT) & HEADER_OBJTAG_MASK),
    size: Number(header & HEADER_SIZE_MASK),
  };
}

/**
 * Encode a PackedTag (RTag + CTag).
 */
export function encodePackedTag(rTag: number, cTag: number): number {
  return ((rTag & 0xffff) << 16) | (cTag & 0xffff);
}

/**
 * Decode a PackedTag.
 */
export function decodePackedTag(packed: number): DecodedPackedTag {
  return {
    rTag: (packed >>> 16) & 0xffff,
    cTag: packed & 0xffff,
  };
}

/**
 * Round up to 8-byte alignment.
 */
export function align8(n: number): number {
  return (n + 7) & ~7;
}

/**
 * Calculate the total size of a Text object.
 */
export function textObjectSize(byteLen: number): number {
  return TEXT_BYTES_OFFSET + align8(byteLen);
}

/**
 * Calculate the total size of a Bytes object.
 */
export function bytesObjectSize(len: number): number {
  return TEXT_BYTES_OFFSET + align8(len);
}

/**
 * Calculate the total size of a DataG object.
 */
export function dataGObjectSize(fieldCount: number): number {
  return DATA_FIELDS_OFFSET + fieldCount * TYPED_SLOT_SIZE;
}

/**
 * Calculate the total size of a PAp object.
 */
export function papObjectSize(capturedCount: number): number {
  return PAP_ARGS_OFFSET + capturedCount * TYPED_SLOT_SIZE;
}

/**
 * Calculate the total size of a Captured object.
 */
export function capturedObjectSize(valueCount: number): number {
  return CAPTURED_VALUES_OFFSET + valueCount * TYPED_SLOT_SIZE;
}

/**
 * Calculate the total size of a Sequence object.
 */
export function sequenceObjectSize(length: number): number {
  return SEQ_ELEMENTS_OFFSET + length * TYPED_SLOT_SIZE;
}

/**
 * Calculate the total size of a Push frame.
 */
export function pushFrameSize(savedCount: number): number {
  return PUSH_SAVED_OFFSET + savedCount * TYPED_SLOT_SIZE;
}

// =============================================================================
// Async Continuation Constants
// =============================================================================

/** Size of an async continuation object */
export const ASYNC_CONT_SIZE = 32;

/** Offset of continuation ID in async cont */
export const ASYNC_CONT_ID_OFFSET = 8;

/** Offset of saved K pointer in async cont */
export const ASYNC_CONT_KPTR_OFFSET = 16;

/** Offset of locals pointer in async cont */
export const ASYNC_CONT_LOCALS_PTR_OFFSET = 20;

/** Offset of locals count in async cont */
export const ASYNC_CONT_LOCALS_COUNT_OFFSET = 24;

/** Offset of status field in async cont */
export const ASYNC_CONT_STATUS_OFFSET = 28;

/** Status: pending (not yet resumed) */
export const ASYNC_STATUS_PENDING = 0;

/** Status: resumed (consumed) */
export const ASYNC_STATUS_RESUMED = 1;

/** Status: freed (cleaned up) */
export const ASYNC_STATUS_FREED = 2;

/**
 * Magic sentinel value indicating async yield.
 * When a function returns this value, it means it yielded to JS.
 * Uses a value that cannot be a valid Nat/Int/pointer.
 */
export const YIELD_SENTINEL = 0xffff_ffff_ffff_fffen;
