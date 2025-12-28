/**
 * Memory allocator for Unison WASM heap objects.
 *
 * This module provides functions to allocate each type of heap object
 * defined in WASM_ABI.md. These are used for testing and for JS-side
 * allocation when needed.
 *
 * All allocators write directly to a DataView and return the pointer
 * to the allocated object.
 *
 * @module wasm-alloc
 */

import {
  ABI_VERSION,
  OBJ_ENUM,
  OBJ_DATA1,
  OBJ_DATA2,
  OBJ_DATAG,
  OBJ_PAP,
  OBJ_CAPTURED,
  OBJ_FOREIGN,
  OBJ_TEXT,
  OBJ_BYTES,
  OBJ_SEQUENCE,
  TYPE_NAT,
  TYPE_BOXED,
  TYPED_SLOT_SIZE,
  ENUM_SIZE,
  DATA1_SIZE,
  DATA2_SIZE,
  FOREIGN_SIZE,
  DATA_TYPEREF_OFFSET,
  DATA_PACKEDTAG_OFFSET,
  DATA_FIELDS_OFFSET,
  PAP_COMBIX_REFID_OFFSET,
  PAP_COMBIX_COMBNUM_OFFSET,
  PAP_EXPECTED_ARITY_OFFSET,
  PAP_CAPTURED_COUNT_OFFSET,
  PAP_ARGS_OFFSET,
  CAPTURED_KHEAD_OFFSET,
  CAPTURED_PENDING_OFFSET,
  CAPTURED_VALUES_OFFSET,
  TEXT_BYTELEN_OFFSET,
  TEXT_CHARLEN_OFFSET,
  TEXT_BYTES_OFFSET,
  SEQ_LENGTH_OFFSET,
  SEQ_CAPACITY_OFFSET,
  SEQ_ELEMENTS_OFFSET,
  FOREIGN_HANDLE_OFFSET,
  FOREIGN_TYPEHINT_OFFSET,
  SLOT_TAG_OFFSET,
  SLOT_PAYLOAD_OFFSET,
  encodeHeader,
  align8,
  textObjectSize,
  bytesObjectSize,
  dataGObjectSize,
  papObjectSize,
  capturedObjectSize,
  sequenceObjectSize,
  type ObjTag,
  type TypeTag,
  type Ptr32,
} from './abi-constants.js';

// =============================================================================
// Type Definitions
// =============================================================================

/**
 * A TypedSlot containing a type tag and 64-bit payload.
 */
export interface TypedSlot {
  tag: TypeTag;
  payload: bigint;
}

/**
 * Heap allocator state for testing.
 */
export interface HeapAllocator {
  view: DataView;
  heapPtr: number;
  heapEnd: number;
}

// =============================================================================
// Allocator Creation
// =============================================================================

/**
 * Create a heap allocator for testing.
 */
export function createHeapAllocator(size: number = 1024 * 1024): HeapAllocator {
  const buffer = new ArrayBuffer(size);
  const view = new DataView(buffer);
  return {
    view,
    heapPtr: 0x10000, // Start after reserved regions
    heapEnd: size,
  };
}

/**
 * Allocate bytes from the heap (bump allocator).
 */
export function heapAlloc(alloc: HeapAllocator, size: number): Ptr32 {
  const alignedSize = align8(size);
  if (alloc.heapPtr + alignedSize > alloc.heapEnd) {
    throw new Error(
      `Out of heap memory: requested ${size} bytes at 0x${alloc.heapPtr.toString(16)}`
    );
  }
  const ptr = alloc.heapPtr;
  alloc.heapPtr += alignedSize;
  return ptr;
}

// =============================================================================
// Header and Slot Writing
// =============================================================================

/**
 * Write the common heap object header.
 */
function writeHeader(view: DataView, ptr: Ptr32, objTag: ObjTag, size: number): void {
  const header = encodeHeader(ABI_VERSION, objTag, size);
  view.setBigUint64(ptr, header, true);
}

/**
 * Write a TypedSlot to memory.
 */
export function writeTypedSlot(view: DataView, ptr: Ptr32, slot: TypedSlot): void {
  // TypeTag in first 8 bytes (with padding)
  view.setBigUint64(ptr + SLOT_TAG_OFFSET, BigInt(slot.tag), true);
  // Payload64 in next 8 bytes
  view.setBigUint64(ptr + SLOT_PAYLOAD_OFFSET, slot.payload, true);
}

/**
 * Read a TypedSlot from memory.
 */
export function readTypedSlot(view: DataView, ptr: Ptr32): TypedSlot {
  const tagWord = view.getBigUint64(ptr + SLOT_TAG_OFFSET, true);
  const tag = Number(tagWord & 0xffn);
  const payload = view.getBigUint64(ptr + SLOT_PAYLOAD_OFFSET, true);
  return { tag, payload };
}

// =============================================================================
// Object Allocators
// =============================================================================

/**
 * Allocate an Enum (nullary constructor).
 */
export function allocEnum(
  alloc: HeapAllocator,
  typeRef: number,
  packedTag: number
): Ptr32 {
  const ptr = heapAlloc(alloc, ENUM_SIZE);
  const { view } = alloc;

  writeHeader(view, ptr, OBJ_ENUM, 0);
  view.setUint32(ptr + DATA_TYPEREF_OFFSET, typeRef, true);
  view.setUint32(ptr + DATA_PACKEDTAG_OFFSET, packedTag, true);

  return ptr;
}

/**
 * Allocate a Data1 (unary constructor).
 */
export function allocData1(
  alloc: HeapAllocator,
  typeRef: number,
  packedTag: number,
  field0: TypedSlot
): Ptr32 {
  const ptr = heapAlloc(alloc, DATA1_SIZE);
  const { view } = alloc;

  writeHeader(view, ptr, OBJ_DATA1, 1);
  view.setUint32(ptr + DATA_TYPEREF_OFFSET, typeRef, true);
  view.setUint32(ptr + DATA_PACKEDTAG_OFFSET, packedTag, true);
  writeTypedSlot(view, ptr + DATA_FIELDS_OFFSET, field0);

  return ptr;
}

/**
 * Allocate a Data2 (binary constructor).
 */
export function allocData2(
  alloc: HeapAllocator,
  typeRef: number,
  packedTag: number,
  field0: TypedSlot,
  field1: TypedSlot
): Ptr32 {
  const ptr = heapAlloc(alloc, DATA2_SIZE);
  const { view } = alloc;

  writeHeader(view, ptr, OBJ_DATA2, 2);
  view.setUint32(ptr + DATA_TYPEREF_OFFSET, typeRef, true);
  view.setUint32(ptr + DATA_PACKEDTAG_OFFSET, packedTag, true);
  writeTypedSlot(view, ptr + DATA_FIELDS_OFFSET, field0);
  writeTypedSlot(view, ptr + DATA_FIELDS_OFFSET + TYPED_SLOT_SIZE, field1);

  return ptr;
}

/**
 * Allocate a DataG (general N-ary constructor).
 */
export function allocDataG(
  alloc: HeapAllocator,
  typeRef: number,
  packedTag: number,
  fields: TypedSlot[]
): Ptr32 {
  const size = dataGObjectSize(fields.length);
  const ptr = heapAlloc(alloc, size);
  const { view } = alloc;

  writeHeader(view, ptr, OBJ_DATAG, fields.length);
  view.setUint32(ptr + DATA_TYPEREF_OFFSET, typeRef, true);
  view.setUint32(ptr + DATA_PACKEDTAG_OFFSET, packedTag, true);

  for (let i = 0; i < fields.length; i++) {
    writeTypedSlot(view, ptr + DATA_FIELDS_OFFSET + i * TYPED_SLOT_SIZE, fields[i]!);
  }

  return ptr;
}

/**
 * Allocate a PAp (partial application / closure).
 */
export function allocPAp(
  alloc: HeapAllocator,
  combIxRefId: number,
  combIxCombNum: number,
  expectedArity: number,
  capturedArgs: TypedSlot[]
): Ptr32 {
  const capturedCount = capturedArgs.length;
  const size = papObjectSize(capturedCount);
  const ptr = heapAlloc(alloc, size);
  const { view } = alloc;

  writeHeader(view, ptr, OBJ_PAP, capturedCount);
  view.setUint32(ptr + PAP_COMBIX_REFID_OFFSET, combIxRefId, true);
  view.setUint32(ptr + PAP_COMBIX_COMBNUM_OFFSET, combIxCombNum, true);
  view.setUint16(ptr + PAP_EXPECTED_ARITY_OFFSET, expectedArity, true);
  view.setUint16(ptr + PAP_CAPTURED_COUNT_OFFSET, capturedCount, true);
  // Reserved 4 bytes at offset 20 are left as zero

  for (let i = 0; i < capturedCount; i++) {
    writeTypedSlot(view, ptr + PAP_ARGS_OFFSET + i * TYPED_SLOT_SIZE, capturedArgs[i]!);
  }

  return ptr;
}

/**
 * Allocate a Captured continuation.
 */
export function allocCaptured(
  alloc: HeapAllocator,
  kHeadPtr: Ptr32,
  pendingArgs: number,
  capturedValues: TypedSlot[]
): Ptr32 {
  const size = capturedObjectSize(capturedValues.length);
  const ptr = heapAlloc(alloc, size);
  const { view } = alloc;

  writeHeader(view, ptr, OBJ_CAPTURED, capturedValues.length);
  view.setUint32(ptr + CAPTURED_KHEAD_OFFSET, kHeadPtr, true);
  view.setUint32(ptr + CAPTURED_PENDING_OFFSET, pendingArgs, true);

  for (let i = 0; i < capturedValues.length; i++) {
    writeTypedSlot(
      view,
      ptr + CAPTURED_VALUES_OFFSET + i * TYPED_SLOT_SIZE,
      capturedValues[i]!
    );
  }

  return ptr;
}

/**
 * Allocate a Foreign object (opaque JS reference).
 */
export function allocForeign(
  alloc: HeapAllocator,
  handleId: number,
  typeHint: number = 0
): Ptr32 {
  const ptr = heapAlloc(alloc, FOREIGN_SIZE);
  const { view } = alloc;

  writeHeader(view, ptr, OBJ_FOREIGN, 0);
  view.setUint32(ptr + FOREIGN_HANDLE_OFFSET, handleId, true);
  view.setUint32(ptr + FOREIGN_TYPEHINT_OFFSET, typeHint, true);

  return ptr;
}

/**
 * Allocate a Text object.
 */
export function allocText(alloc: HeapAllocator, content: string): Ptr32 {
  const encoder = new TextEncoder();
  const bytes = encoder.encode(content);
  const byteLen = bytes.length;
  // Character length = number of Unicode codepoints
  const charLen = [...content].length;

  const size = textObjectSize(byteLen);
  const ptr = heapAlloc(alloc, size);
  const { view } = alloc;

  writeHeader(view, ptr, OBJ_TEXT, byteLen);
  view.setUint32(ptr + TEXT_BYTELEN_OFFSET, byteLen, true);
  view.setUint32(ptr + TEXT_CHARLEN_OFFSET, charLen, true);

  // Write UTF-8 bytes
  const memBytes = new Uint8Array(view.buffer, ptr + TEXT_BYTES_OFFSET, byteLen);
  memBytes.set(bytes);

  return ptr;
}

/**
 * Allocate a Bytes object.
 */
export function allocBytes(alloc: HeapAllocator, content: Uint8Array): Ptr32 {
  const len = content.length;
  const size = bytesObjectSize(len);
  const ptr = heapAlloc(alloc, size);
  const { view } = alloc;

  writeHeader(view, ptr, OBJ_BYTES, len);
  view.setUint32(ptr + TEXT_BYTELEN_OFFSET, len, true);
  view.setUint32(ptr + TEXT_CHARLEN_OFFSET, 0, true); // Reserved for Bytes

  // Write raw bytes
  const memBytes = new Uint8Array(view.buffer, ptr + TEXT_BYTES_OFFSET, len);
  memBytes.set(content);

  return ptr;
}

/**
 * Allocate a Sequence object.
 */
export function allocSequence(alloc: HeapAllocator, elements: TypedSlot[]): Ptr32 {
  const length = elements.length;
  const size = sequenceObjectSize(length);
  const ptr = heapAlloc(alloc, size);
  const { view } = alloc;

  writeHeader(view, ptr, OBJ_SEQUENCE, length);
  view.setUint32(ptr + SEQ_LENGTH_OFFSET, length, true);
  view.setUint32(ptr + SEQ_CAPACITY_OFFSET, length, true); // capacity = length for now

  for (let i = 0; i < length; i++) {
    writeTypedSlot(view, ptr + SEQ_ELEMENTS_OFFSET + i * TYPED_SLOT_SIZE, elements[i]!);
  }

  return ptr;
}

// =============================================================================
// Convenience constructors for TypedSlots
// =============================================================================

/**
 * Create a Nat TypedSlot.
 */
export function natSlot(value: bigint | number): TypedSlot {
  return { tag: TYPE_NAT, payload: BigInt(value) };
}

/**
 * Create an Int TypedSlot.
 */
export function intSlot(value: bigint | number): TypedSlot {
  return { tag: 0x01, payload: BigInt(value) };
}

/**
 * Create a Float TypedSlot.
 */
export function floatSlot(value: number): TypedSlot {
  // Store float bits as bigint
  const buf = new ArrayBuffer(8);
  new Float64Array(buf)[0] = value;
  const bits = new BigUint64Array(buf)[0]!;
  return { tag: 0x02, payload: bits };
}

/**
 * Create a Char TypedSlot.
 */
export function charSlot(char: string): TypedSlot {
  const codepoint = char.codePointAt(0) ?? 0;
  return { tag: 0x03, payload: BigInt(codepoint) };
}

/**
 * Create a Boxed TypedSlot (pointer to heap object).
 */
export function boxedSlot(ptr: Ptr32): TypedSlot {
  return { tag: TYPE_BOXED, payload: BigInt(ptr) };
}
