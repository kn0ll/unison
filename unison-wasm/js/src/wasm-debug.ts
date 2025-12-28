/**
 * Memory inspector and debug utilities for Unison WASM heap.
 *
 * This module provides functions to decode and inspect heap objects,
 * useful for debugging and testing ABI conformance.
 *
 * @module wasm-debug
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
  OBJ_TAG_NAMES,
  TYPE_NAT,
  TYPE_INT,
  TYPE_FLOAT,
  TYPE_CHAR,
  TYPE_BOXED,
  TYPE_TAG_NAMES,
  FRAME_KE,
  FRAME_PUSH,
  FRAME_MARK,
  FRAME_TAG_NAMES,
  TYPED_SLOT_SIZE,
  HEADER_SIZE,
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
  KFRAME_TAG_OFFSET,
  KFRAME_NEXT_OFFSET,
  PUSH_SAVEDCOUNT_OFFSET,
  PUSH_PENDINGARGS_OFFSET,
  PUSH_COMBIX_OFFSET,
  PUSH_SAVED_OFFSET,
  MARK_PENDINGARGS_OFFSET,
  MARK_ABILITIES_OFFSET,
  MARK_DENV_OFFSET,
  decodeHeader,
  decodePackedTag,
  type ObjTag,
  type TypeTag,
  type FrameTag,
  type Ptr32,
} from './abi-constants.js';

import { readTypedSlot } from './wasm-alloc.js';

import { InvalidObjTagError } from './errors.js';

// =============================================================================
// Type Definitions
// =============================================================================

/**
 * A decoded TypedSlot with human-readable information.
 */
export interface DecodedTypedSlot {
  tag: TypeTag;
  tagName: string;
  payload: bigint;
  value: bigint | number | string;
}

/**
 * Decoded enum object data.
 */
export interface DecodedEnumData {
  typeRef: number;
  packedTag: number;
  rTag: number;
  cTag: number;
}

/**
 * Decoded data object (Data1, Data2, DataG).
 */
export interface DecodedDataData {
  typeRef: number;
  packedTag: number;
  rTag: number;
  cTag: number;
  fields: DecodedTypedSlot[];
}

/**
 * Decoded PAp object data.
 */
export interface DecodedPApData {
  combIx: { refId: number; combNum: number };
  expectedArity: number;
  capturedCount: number;
  remainingArity: number;
  args: DecodedTypedSlot[];
}

/**
 * Decoded Captured object data.
 */
export interface DecodedCapturedData {
  kHeadPtr: Ptr32;
  pendingArgs: number;
  values: DecodedTypedSlot[];
}

/**
 * Decoded Foreign object data.
 */
export interface DecodedForeignData {
  handleId: number;
  typeHint: number;
}

/**
 * Decoded Text object data.
 */
export interface DecodedTextData {
  byteLen: number;
  charLen: number;
  content: string;
}

/**
 * Decoded Bytes object data.
 */
export interface DecodedBytesData {
  length: number;
  bytes: number[];
  preview: string;
}

/**
 * Decoded Sequence object data.
 */
export interface DecodedSequenceData {
  length: number;
  capacity: number;
  elements: DecodedTypedSlot[];
}

/**
 * Union of all decoded object data types.
 */
export type DecodedObjectData =
  | DecodedEnumData
  | DecodedDataData
  | DecodedPApData
  | DecodedCapturedData
  | DecodedForeignData
  | DecodedTextData
  | DecodedBytesData
  | DecodedSequenceData;

/**
 * A decoded heap object.
 */
export interface DecodedObject {
  ptr: Ptr32;
  version: number;
  objTag: ObjTag;
  objTagName: string;
  size: number;
  data: DecodedObjectData;
}

/**
 * A decoded K frame.
 */
export interface DecodedKFrame {
  ptr?: Ptr32;
  frameTag: FrameTag;
  frameTagName: string;
  next: Ptr32;
  savedCount?: number;
  pendingArgs?: number;
  combIx?: { ref: number; num: number };
  saved?: DecodedTypedSlot[];
  abilitiesPtr?: Ptr32;
  denvPtr?: Ptr32;
}

// =============================================================================
// Slot Decoding
// =============================================================================

/**
 * Decode a TypedSlot into a human-readable form.
 */
export function decodeTypedSlot(view: DataView, ptr: Ptr32): DecodedTypedSlot {
  const slot = readTypedSlot(view, ptr);
  const tagName = TYPE_TAG_NAMES[slot.tag] ?? `Unknown(0x${slot.tag.toString(16)})`;

  let value: bigint | number | string;
  switch (slot.tag) {
    case TYPE_NAT:
      value = slot.payload;
      break;
    case TYPE_INT:
      // Interpret as signed
      value = BigInt.asIntN(64, slot.payload);
      break;
    case TYPE_FLOAT: {
      // Interpret bits as float64
      const buf = new ArrayBuffer(8);
      new BigUint64Array(buf)[0] = slot.payload;
      value = new Float64Array(buf)[0]!;
      break;
    }
    case TYPE_CHAR:
      value = String.fromCodePoint(Number(slot.payload));
      break;
    case TYPE_BOXED:
      value = `ptr:0x${Number(slot.payload & 0xffffffffn).toString(16)}`;
      break;
    default:
      value = slot.payload;
  }

  return {
    tag: slot.tag,
    tagName,
    payload: slot.payload,
    value,
  };
}

// =============================================================================
// Object Decoding
// =============================================================================

/**
 * Decode a heap object at the given pointer.
 */
export function decodeObject(view: DataView, ptr: Ptr32): DecodedObject {
  const headerWord = view.getBigUint64(ptr, true);
  const { version, objTag, size } = decodeHeader(headerWord);
  const objTagName = OBJ_TAG_NAMES[objTag] ?? `Unknown(0x${objTag.toString(16)})`;

  if (version !== ABI_VERSION) {
    console.warn(
      `Warning: Object at 0x${ptr.toString(16)} has ABI version ${version}, expected ${ABI_VERSION}`
    );
  }

  let data: DecodedObjectData;
  switch (objTag) {
    case OBJ_ENUM:
      data = decodeEnum(view, ptr);
      break;
    case OBJ_DATA1:
      data = decodeData1(view, ptr);
      break;
    case OBJ_DATA2:
      data = decodeData2(view, ptr);
      break;
    case OBJ_DATAG:
      data = decodeDataG(view, ptr, size);
      break;
    case OBJ_PAP:
      data = decodePAp(view, ptr, size);
      break;
    case OBJ_CAPTURED:
      data = decodeCaptured(view, ptr, size);
      break;
    case OBJ_FOREIGN:
      data = decodeForeign(view, ptr);
      break;
    case OBJ_TEXT:
      data = decodeText(view, ptr);
      break;
    case OBJ_BYTES:
      data = decodeBytes(view, ptr);
      break;
    case OBJ_SEQUENCE:
      data = decodeSequence(view, ptr);
      break;
    default:
      throw new InvalidObjTagError(objTag, ptr);
  }

  return {
    ptr,
    version,
    objTag,
    objTagName,
    size,
    data,
  };
}

/**
 * Decode an Enum object.
 */
function decodeEnum(view: DataView, ptr: Ptr32): DecodedEnumData {
  const typeRef = view.getUint32(ptr + DATA_TYPEREF_OFFSET, true);
  const packedTag = view.getUint32(ptr + DATA_PACKEDTAG_OFFSET, true);
  const { rTag, cTag } = decodePackedTag(packedTag);

  return {
    typeRef,
    packedTag,
    rTag,
    cTag,
  };
}

/**
 * Decode a Data1 object.
 */
function decodeData1(view: DataView, ptr: Ptr32): DecodedDataData {
  const typeRef = view.getUint32(ptr + DATA_TYPEREF_OFFSET, true);
  const packedTag = view.getUint32(ptr + DATA_PACKEDTAG_OFFSET, true);
  const { rTag, cTag } = decodePackedTag(packedTag);
  const field0 = decodeTypedSlot(view, ptr + DATA_FIELDS_OFFSET);

  return {
    typeRef,
    packedTag,
    rTag,
    cTag,
    fields: [field0],
  };
}

/**
 * Decode a Data2 object.
 */
function decodeData2(view: DataView, ptr: Ptr32): DecodedDataData {
  const typeRef = view.getUint32(ptr + DATA_TYPEREF_OFFSET, true);
  const packedTag = view.getUint32(ptr + DATA_PACKEDTAG_OFFSET, true);
  const { rTag, cTag } = decodePackedTag(packedTag);
  const field0 = decodeTypedSlot(view, ptr + DATA_FIELDS_OFFSET);
  const field1 = decodeTypedSlot(view, ptr + DATA_FIELDS_OFFSET + TYPED_SLOT_SIZE);

  return {
    typeRef,
    packedTag,
    rTag,
    cTag,
    fields: [field0, field1],
  };
}

/**
 * Decode a DataG object.
 */
function decodeDataG(view: DataView, ptr: Ptr32, fieldCount: number): DecodedDataData {
  const typeRef = view.getUint32(ptr + DATA_TYPEREF_OFFSET, true);
  const packedTag = view.getUint32(ptr + DATA_PACKEDTAG_OFFSET, true);
  const { rTag, cTag } = decodePackedTag(packedTag);

  const fields: DecodedTypedSlot[] = [];
  for (let i = 0; i < fieldCount; i++) {
    fields.push(decodeTypedSlot(view, ptr + DATA_FIELDS_OFFSET + i * TYPED_SLOT_SIZE));
  }

  return {
    typeRef,
    packedTag,
    rTag,
    cTag,
    fields,
  };
}

/**
 * Decode a PAp object.
 */
function decodePAp(view: DataView, ptr: Ptr32, capturedCount: number): DecodedPApData {
  const combIxRefId = view.getUint32(ptr + PAP_COMBIX_REFID_OFFSET, true);
  const combIxCombNum = view.getUint32(ptr + PAP_COMBIX_COMBNUM_OFFSET, true);
  const expectedArity = view.getUint16(ptr + PAP_EXPECTED_ARITY_OFFSET, true);
  const capturedCountField = view.getUint16(ptr + PAP_CAPTURED_COUNT_OFFSET, true);

  const args: DecodedTypedSlot[] = [];
  for (let i = 0; i < capturedCount; i++) {
    args.push(decodeTypedSlot(view, ptr + PAP_ARGS_OFFSET + i * TYPED_SLOT_SIZE));
  }

  return {
    combIx: {
      refId: combIxRefId,
      combNum: combIxCombNum,
    },
    expectedArity,
    capturedCount: capturedCountField,
    remainingArity: expectedArity - capturedCountField,
    args,
  };
}

/**
 * Decode a Captured object.
 */
function decodeCaptured(view: DataView, ptr: Ptr32, valueCount: number): DecodedCapturedData {
  const kHeadPtr = view.getUint32(ptr + CAPTURED_KHEAD_OFFSET, true);
  const pendingArgs = view.getUint32(ptr + CAPTURED_PENDING_OFFSET, true);

  const values: DecodedTypedSlot[] = [];
  for (let i = 0; i < valueCount; i++) {
    values.push(
      decodeTypedSlot(view, ptr + CAPTURED_VALUES_OFFSET + i * TYPED_SLOT_SIZE)
    );
  }

  return {
    kHeadPtr,
    pendingArgs,
    values,
  };
}

/**
 * Decode a Foreign object.
 */
function decodeForeign(view: DataView, ptr: Ptr32): DecodedForeignData {
  const handleId = view.getUint32(ptr + FOREIGN_HANDLE_OFFSET, true);
  const typeHint = view.getUint32(ptr + FOREIGN_TYPEHINT_OFFSET, true);

  return {
    handleId,
    typeHint,
  };
}

/**
 * Decode a Text object.
 */
function decodeText(view: DataView, ptr: Ptr32): DecodedTextData {
  const byteLen = view.getUint32(ptr + TEXT_BYTELEN_OFFSET, true);
  const charLen = view.getUint32(ptr + TEXT_CHARLEN_OFFSET, true);

  const bytes = new Uint8Array(view.buffer, ptr + TEXT_BYTES_OFFSET, byteLen);
  const decoder = new TextDecoder();
  const content = decoder.decode(bytes);

  return {
    byteLen,
    charLen,
    content,
  };
}

/**
 * Decode a Bytes object.
 */
function decodeBytes(view: DataView, ptr: Ptr32): DecodedBytesData {
  const byteLen = view.getUint32(ptr + TEXT_BYTELEN_OFFSET, true);
  const bytes = new Uint8Array(view.buffer, ptr + TEXT_BYTES_OFFSET, byteLen);

  return {
    length: byteLen,
    bytes: Array.from(bytes),
    preview: bytes.length <= 32
      ? Array.from(bytes).map((b) => b.toString(16).padStart(2, '0')).join(' ')
      : Array.from(bytes.slice(0, 32)).map((b) => b.toString(16).padStart(2, '0')).join(' ') + '...',
  };
}

/**
 * Decode a Sequence object.
 */
function decodeSequence(view: DataView, ptr: Ptr32): DecodedSequenceData {
  const len = view.getUint32(ptr + SEQ_LENGTH_OFFSET, true);
  const capacity = view.getUint32(ptr + SEQ_CAPACITY_OFFSET, true);

  const elements: DecodedTypedSlot[] = [];
  for (let i = 0; i < len; i++) {
    elements.push(
      decodeTypedSlot(view, ptr + SEQ_ELEMENTS_OFFSET + i * TYPED_SLOT_SIZE)
    );
  }

  return {
    length: len,
    capacity,
    elements,
  };
}

// =============================================================================
// K Frame Decoding
// =============================================================================

/**
 * Decode a K frame at the given pointer.
 */
export function decodeKFrame(view: DataView, ptr: Ptr32): DecodedKFrame {
  if (ptr === 0) {
    return { frameTag: FRAME_KE, frameTagName: 'KE', next: 0 };
  }

  const frameTag = view.getUint8(ptr + KFRAME_TAG_OFFSET);
  const next = view.getUint32(ptr + KFRAME_NEXT_OFFSET, true);
  const frameTagName = FRAME_TAG_NAMES[frameTag] ?? `Unknown(0x${frameTag.toString(16)})`;

  const result: DecodedKFrame = {
    ptr,
    frameTag,
    frameTagName,
    next,
  };

  switch (frameTag) {
    case FRAME_KE:
      break;
    case FRAME_PUSH: {
      const pushData = decodePushFrame(view, ptr);
      Object.assign(result, pushData);
      break;
    }
    case FRAME_MARK: {
      const markData = decodeMarkFrame(view, ptr);
      Object.assign(result, markData);
      break;
    }
  }

  return result;
}

/**
 * Decode a Push frame.
 */
function decodePushFrame(view: DataView, ptr: Ptr32): Partial<DecodedKFrame> {
  const savedCount = view.getUint32(ptr + PUSH_SAVEDCOUNT_OFFSET, true);
  const pendingArgs = view.getUint32(ptr + PUSH_PENDINGARGS_OFFSET, true);
  const combIxRef = view.getUint32(ptr + PUSH_COMBIX_OFFSET, true);
  const combIxNum = view.getUint32(ptr + PUSH_COMBIX_OFFSET + 4, true);

  const saved: DecodedTypedSlot[] = [];
  for (let i = 0; i < savedCount; i++) {
    saved.push(decodeTypedSlot(view, ptr + PUSH_SAVED_OFFSET + i * TYPED_SLOT_SIZE));
  }

  return {
    savedCount,
    pendingArgs,
    combIx: { ref: combIxRef, num: combIxNum },
    saved,
  };
}

/**
 * Decode a Mark frame.
 */
function decodeMarkFrame(view: DataView, ptr: Ptr32): Partial<DecodedKFrame> {
  const pendingArgs = view.getUint32(ptr + MARK_PENDINGARGS_OFFSET, true);
  const abilitiesPtr = view.getUint32(ptr + MARK_ABILITIES_OFFSET, true);
  const denvPtr = view.getUint32(ptr + MARK_DENV_OFFSET, true);

  return {
    pendingArgs,
    abilitiesPtr,
    denvPtr,
  };
}

/**
 * Walk the K frame chain and return all frames.
 */
export function walkKChain(view: DataView, kHeadPtr: Ptr32, maxDepth: number = 100): DecodedKFrame[] {
  const frames: DecodedKFrame[] = [];
  let ptr = kHeadPtr;
  let depth = 0;

  while (ptr !== 0 && depth < maxDepth) {
    const frame = decodeKFrame(view, ptr);
    frames.push(frame);
    ptr = frame.next;
    depth++;
  }

  return frames;
}

// =============================================================================
// Formatting
// =============================================================================

/**
 * Format a value for display.
 */
function formatValue(value: bigint | number | string): string {
  if (typeof value === 'bigint') {
    return value.toString();
  }
  if (typeof value === 'string') {
    return value.length > 50 ? `"${value.slice(0, 50)}..."` : `"${value}"`;
  }
  return String(value);
}

/**
 * Format a decoded object for console output.
 */
export function formatObject(obj: DecodedObject): string {
  const lines: string[] = [];
  lines.push(`${obj.objTagName} @ 0x${obj.ptr.toString(16)} (v${obj.version}, size=${obj.size})`);

  switch (obj.objTag) {
    case OBJ_ENUM: {
      const data = obj.data as DecodedEnumData;
      lines.push(`  typeRef: ${data.typeRef}, rTag: ${data.rTag}, cTag: ${data.cTag}`);
      break;
    }

    case OBJ_DATA1:
    case OBJ_DATA2:
    case OBJ_DATAG: {
      const data = obj.data as DecodedDataData;
      lines.push(`  typeRef: ${data.typeRef}, rTag: ${data.rTag}, cTag: ${data.cTag}`);
      data.fields.forEach((f, i) => {
        lines.push(`  field[${i}]: ${f.tagName} = ${formatValue(f.value)}`);
      });
      break;
    }

    case OBJ_PAP: {
      const data = obj.data as DecodedPApData;
      lines.push(`  combIx: (${data.combIx.refId}, ${data.combIx.combNum})`);
      lines.push(`  arity: ${data.capturedCount}/${data.expectedArity} (${data.remainingArity} remaining)`);
      data.args.forEach((a, i) => {
        lines.push(`  arg[${i}]: ${a.tagName} = ${formatValue(a.value)}`);
      });
      break;
    }

    case OBJ_CAPTURED: {
      const data = obj.data as DecodedCapturedData;
      lines.push(`  kHeadPtr: 0x${data.kHeadPtr.toString(16)}`);
      lines.push(`  pendingArgs: ${data.pendingArgs}`);
      lines.push(`  values: ${data.values.length}`);
      break;
    }

    case OBJ_FOREIGN: {
      const data = obj.data as DecodedForeignData;
      lines.push(`  handleId: ${data.handleId}, typeHint: ${data.typeHint}`);
      break;
    }

    case OBJ_TEXT: {
      const data = obj.data as DecodedTextData;
      lines.push(`  byteLen: ${data.byteLen}, charLen: ${data.charLen}`);
      lines.push(`  content: "${data.content}"`);
      break;
    }

    case OBJ_BYTES: {
      const data = obj.data as DecodedBytesData;
      lines.push(`  length: ${data.length}`);
      lines.push(`  bytes: ${data.preview}`);
      break;
    }

    case OBJ_SEQUENCE: {
      const data = obj.data as DecodedSequenceData;
      lines.push(`  length: ${data.length}, capacity: ${data.capacity}`);
      data.elements.slice(0, 10).forEach((e, i) => {
        lines.push(`  [${i}]: ${e.tagName} = ${formatValue(e.value)}`);
      });
      if (data.elements.length > 10) {
        lines.push(`  ... and ${data.elements.length - 10} more`);
      }
      break;
    }
  }

  return lines.join('\n');
}

/**
 * Inspect a region of memory and print decoded objects.
 */
export function inspectMemory(view: DataView, startPtr: Ptr32, count: number = 10): void {
  console.log(`=== Memory inspection starting at 0x${startPtr.toString(16)} ===\n`);

  let ptr = startPtr;
  let decoded = 0;

  while (decoded < count && ptr < view.byteLength - HEADER_SIZE) {
    try {
      const obj = decodeObject(view, ptr);
      console.log(formatObject(obj));
      console.log('');

      // Calculate object size and move to next
      let objSize: number;
      switch (obj.objTag) {
        case OBJ_ENUM:
          objSize = 16;
          break;
        case OBJ_DATA1:
          objSize = 32;
          break;
        case OBJ_DATA2:
          objSize = 48;
          break;
        case OBJ_DATAG:
          objSize = 16 + obj.size * TYPED_SLOT_SIZE;
          break;
        case OBJ_PAP:
          objSize = 24 + obj.size * TYPED_SLOT_SIZE;
          break;
        case OBJ_CAPTURED:
          objSize = 16 + obj.size * TYPED_SLOT_SIZE;
          break;
        case OBJ_FOREIGN:
          objSize = 16;
          break;
        case OBJ_TEXT:
        case OBJ_BYTES:
          objSize = 16 + ((obj.size + 7) & ~7);
          break;
        case OBJ_SEQUENCE:
          objSize = 16 + obj.size * TYPED_SLOT_SIZE;
          break;
        default:
          objSize = 16;
      }

      ptr += objSize;
      decoded++;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.log(`Error at 0x${ptr.toString(16)}: ${msg}`);
      ptr += 8; // Try next aligned position
    }
  }

  console.log(`=== End of inspection (${decoded} objects) ===`);
}

/**
 * Create a memory dump in hex format.
 */
export function hexDump(view: DataView, start: Ptr32, length: number): string {
  const lines: string[] = [];
  const bytesPerLine = 16;

  for (let offset = 0; offset < length; offset += bytesPerLine) {
    const addr = (start + offset).toString(16).padStart(8, '0');
    const hexParts: string[] = [];
    const asciiParts: string[] = [];

    for (let i = 0; i < bytesPerLine; i++) {
      if (offset + i < length) {
        const byte = view.getUint8(start + offset + i);
        hexParts.push(byte.toString(16).padStart(2, '0'));
        asciiParts.push(byte >= 32 && byte <= 126 ? String.fromCharCode(byte) : '.');
      } else {
        hexParts.push('  ');
        asciiParts.push(' ');
      }
    }

    const hex = hexParts.join(' ');
    const ascii = asciiParts.join('');
    lines.push(`${addr}  ${hex}  |${ascii}|`);
  }

  return lines.join('\n');
}
